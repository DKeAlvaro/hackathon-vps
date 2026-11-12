#!/usr/bin/env bash
# Connect this computer to the shared hackathon VPS (macOS, Linux, Git Bash on Windows).
# Usage: ./connect.sh [-u NAME] [--no-pr] [--wait MINUTES] [--check] [--print]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"
NAME_RE='^[a-z][a-z0-9-]{0,30}$'
BEGIN_MARK='# >>> hackathon-vps >>>'
END_MARK='# <<< hackathon-vps <<<'

USER_ARG="${HACK_USER:-}"
NO_PR=0
WAIT_MIN=0
CHECK=0
PRINT=0

usage() {
  cat <<'EOF'
Usage: ./connect.sh [options]
  -u, --user NAME   Linux username (lowercase, ^[a-z][a-z0-9-]{0,30}$). Default: $HACK_USER,
                    then your GitHub login (if gh is logged in), then it asks.
  --no-pr           Do not push or open a pull request; just print the public key.
  --wait MINUTES    After requesting access, poll every 15 s for up to MINUTES (default 0).
  --check           Only test whether `ssh hack` works now. Exit 0 if yes, 1 if not.
  --print           Only print the ssh config block and your public key.
  -h, --help        This help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; USER_ARG="$2"; shift 2 ;;
    --user=*) USER_ARG="${1#--user=}"; shift ;;
    --no-pr) NO_PR=1; shift ;;
    --wait) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; WAIT_MIN="$2"; shift 2 ;;
    --wait=*) WAIT_MIN="${1#--wait=}"; shift ;;
    --check) CHECK=1; shift ;;
    --print) PRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$WAIT_MIN" in ''|*[!0-9]*) echo "--wait needs a whole number of minutes" >&2; exit 2 ;; esac

step() { printf '\n[%s] %s\n' "$1" "$2"; }

# ---- 1. read hack.conf --------------------------------------------------------
step 1 "Reading hack.conf"
conf_get() { sed -n "s/^$1=//p" "$ROOT/hack.conf" | head -n1 | tr -d '\r'; }
[ -f "$ROOT/hack.conf" ] || { echo "hack.conf not found in $ROOT" >&2; exit 1; }
HOST_ALIAS="$(conf_get HOST_ALIAS)"
HOST_IP="$(conf_get HOST_IP)"
SSH_PORT="$(conf_get SSH_PORT)"
REPO="$(conf_get REPO)"
if [ -z "$HOST_ALIAS" ] || [ -z "$HOST_IP" ] || [ -z "$SSH_PORT" ] || [ -z "$REPO" ]; then
  echo "hack.conf is incomplete (need HOST_ALIAS, HOST_IP, SSH_PORT, REPO)." >&2
  exit 1
fi
if [ "$HOST_IP" = "__VPS_IP__" ]; then
  echo "hack.conf still has the placeholder HOST_IP=__VPS_IP__." >&2
  echo "The repo owner has not filled in the server IP yet. Ask the admin (DKeAlvaro) and pull again." >&2
  exit 1
fi
echo "host alias $HOST_ALIAS -> $HOST_IP:$SSH_PORT, repo $REPO"

ssh_ok() { ssh -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=QUIET "$HOST_ALIAS" true >/dev/null 2>&1; }

if [ "$CHECK" -eq 1 ]; then
  if ssh_ok; then echo "OK: ssh $HOST_ALIAS works"; exit 0; fi
  echo "NOT YET: ssh $HOST_ALIAS does not work"
  exit 1
fi

# ---- 2. username --------------------------------------------------------------
step 2 "Choosing the Linux username"
USERNAME="$USER_ARG"
if [ -z "$USERNAME" ] && command -v gh >/dev/null 2>&1; then
  guess="$(gh api user -q .login 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\r' || true)"
  if [[ "$guess" =~ $NAME_RE ]]; then
    USERNAME="$guess"
    echo "derived from GitHub login: $USERNAME"
  fi
fi
if [ -z "$USERNAME" ]; then
  if [ -t 0 ]; then
    read -r -p "Username on the VPS (lowercase letters, digits, hyphens): " USERNAME
  else
    echo "No username known and no terminal to ask. Re-run with: ./connect.sh -u <name>" >&2
    exit 1
  fi
fi
USERNAME="$(printf '%s' "$USERNAME" | tr '[:upper:]' '[:lower:]')"
if ! [[ "$USERNAME" =~ $NAME_RE ]]; then
  echo "Invalid username '$USERNAME': must match $NAME_RE" >&2
  exit 1
fi
echo "username: $USERNAME"

# ---- 3. key -------------------------------------------------------------------
step 3 "SSH key"
SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/hack_ed25519"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR" 2>/dev/null || true
if [ -f "$KEY" ]; then
  echo "using existing key $KEY"
else
  echo "creating $KEY"
  ssh-keygen -q -t ed25519 -N "" -C "$USERNAME@hackathon" -f "$KEY"
fi
[ -f "$KEY.pub" ] || ssh-keygen -y -f "$KEY" > "$KEY.pub"
PUBKEY="$(tr -d '\r' < "$KEY.pub" | head -n1)"
KEYBLOB="$(printf '%s' "$PUBKEY" | awk '{print $2}')"

CONFIG_BLOCK="$BEGIN_MARK
Host $HOST_ALIAS
    HostName $HOST_IP
    Port $SSH_PORT
    User $USERNAME
    IdentityFile ~/.ssh/hack_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 6
    StrictHostKeyChecking accept-new
$END_MARK"

if [ "$PRINT" -eq 1 ]; then
  echo
  echo "--- ssh config block ($SSH_DIR/config) ---"
  echo "$CONFIG_BLOCK"
  echo
  echo "--- public key (keys/$USERNAME.pub) ---"
  echo "$PUBKEY"
  exit 0
fi

# ---- 4. ssh config ------------------------------------------------------------
step 4 "Updating $SSH_DIR/config"
CFG="$SSH_DIR/config"
touch "$CFG"
rest="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  !skip' "$CFG")"
{
  if [ -n "$rest" ]; then printf '%s\n\n' "$rest"; fi
  printf '%s\n' "$CONFIG_BLOCK"
} > "$CFG.hacktmp"
if cmp -s "$CFG.hacktmp" "$CFG"; then
  rm -f "$CFG.hacktmp"
  echo "config block already up to date"
else
  mv "$CFG.hacktmp" "$CFG"
  echo "config block written"
fi
chmod 600 "$CFG" 2>/dev/null || true

# ---- 5. test ------------------------------------------------------------------
next_steps() {
  cat <<EOF

You are connected. Next:
  ssh $HOST_ALIAS            open a shell on the VPS
  pair                       (on the VPS) shared tmux session with the team
  ~/hack                     shared projects folder (/srv/hack)
  VS Code / Cursor: Remote-SSH, connect to host "$HOST_ALIAS"
EOF
}

step 5 "Testing ssh $HOST_ALIAS"
if ssh_ok; then
  echo "ssh $HOST_ALIAS works"
  next_steps
  exit 0
fi
echo "not connected yet (account probably does not exist yet)"

# ---- 6. membership ------------------------------------------------------------
step 6 "Requesting access (keys/$USERNAME.pub)"
mkdir -p "$ROOT/keys"
KEYFILE="$ROOT/keys/$USERNAME.pub"
if [ -f "$KEYFILE" ] && grep -qF "$KEYBLOB" "$KEYFILE"; then
  echo "local keys/$USERNAME.pub already has your key"
else
  [ -f "$KEYFILE" ] && [ -n "$(tail -c1 "$KEYFILE")" ] && echo >> "$KEYFILE"
  printf '%s\n' "$PUBKEY" >> "$KEYFILE"
  echo "wrote your key to keys/$USERNAME.pub"
fi

print_manual() {
  cat <<EOF

Send this public key to the admin (DKeAlvaro), or open a pull request on
https://github.com/$REPO adding it as keys/$USERNAME.pub:

$PUBKEY

EOF
}

GIT_GH=(-c credential.helper= -c "credential.helper=!gh auth git-credential")

submit_with_gh() {
  local login can_push tmp attempt
  login="$(gh api user -q .login | tr -d '\r')"
  can_push="$(gh api "repos/$REPO" -q .permissions.push 2>/dev/null | tr -d '\r' || true)"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  git clone -q --depth 1 "https://github.com/$REPO.git" "$tmp/repo"
  local g=(git -C "$tmp/repo")
  if ! "${g[@]}" config user.email >/dev/null 2>&1; then
    g+=(-c "user.name=$login" -c "user.email=$login@users.noreply.github.com")
  fi
  mkdir -p "$tmp/repo/keys"
  local target="$tmp/repo/keys/$USERNAME.pub"
  if [ -f "$target" ] && grep -qF "$KEYBLOB" "$target"; then
    echo "your key is already in $REPO main; the VPS picks it up within a minute"
    return 0
  fi
  if [ -f "$target" ]; then
    echo "WARNING: keys/$USERNAME.pub already exists upstream with other keys; adding yours as an extra line" >&2
    [ -n "$(tail -c1 "$target")" ] && echo >> "$target"
  fi
  printf '%s\n' "$PUBKEY" >> "$target"

  if [ "$can_push" = "true" ]; then
    echo "you have push access: committing to main"
    "${g[@]}" add "keys/$USERNAME.pub"
    "${g[@]}" commit -q -m "Add $USERNAME"
    git -C "$tmp/repo" "${GIT_GH[@]}" push -q "https://github.com/$REPO.git" HEAD:main
    echo "pushed to main"
    return 0
  fi

  local branch="add-$USERNAME" existing
  existing="$(gh pr list --repo "$REPO" --head "$login:$branch" --state open --json number -q length 2>/dev/null | tr -d '\r' || echo 0)"
  "${g[@]}" checkout -q -b "$branch"
  "${g[@]}" add "keys/$USERNAME.pub"
  "${g[@]}" commit -q -m "Add $USERNAME"
  gh repo fork "$REPO" --clone=false >/dev/null 2>&1 || true
  local fork_url="https://github.com/$login/${REPO#*/}.git"
  for attempt in 1 2 3 4 5; do
    if git -C "$tmp/repo" "${GIT_GH[@]}" push -q --force "$fork_url" "$branch"; then break; fi
    [ "$attempt" -lt 5 ] || { echo "could not push to your fork $fork_url" >&2; return 1; }
    echo "fork not ready, retrying..."; sleep 4
  done
  if [ "${existing:-0}" != "0" ]; then
    echo "a pull request from $login:$branch is already open; updated it"
  else
    gh pr create --repo "$REPO" --base main --head "$login:$branch" \
      --title "Add $USERNAME" --body "Adds keys/$USERNAME.pub so $USERNAME can access the hackathon VPS."
  fi
  echo "Ask the admin (DKeAlvaro) to merge the pull request; the account appears within about a minute."
}

if [ "$NO_PR" -eq 1 ]; then
  echo "--no-pr given: not pushing anything"
  print_manual
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if ! submit_with_gh; then
    echo "Automatic submission failed." >&2
    print_manual
  fi
else
  echo "gh is not installed or not logged in"
  print_manual
fi

# ---- 7. wait ------------------------------------------------------------------
step 7 "Waiting for access"
if [ "$WAIT_MIN" -gt 0 ]; then
  deadline=$(( $(date +%s) + WAIT_MIN * 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ssh_ok; then
      echo "ssh $HOST_ALIAS works"
      next_steps
      exit 0
    fi
    echo "not yet, retrying in 15 s..."
    sleep 15
  done
  echo "Timed out after $WAIT_MIN minute(s). Re-run ./connect.sh --check later."
  exit 1
fi
echo "Not waiting. Once the admin has merged, check with:  ./connect.sh --check"
echo "(or keep polling with ./connect.sh --wait 10)"
exit 1
