#!/usr/bin/env bash
# Connect this computer to the shared hackathon VPS (macOS, Linux, Git Bash on Windows).
# Usage: ./connect.sh -u NAME -c CODE [--check] [--print]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd)"
BEGIN_MARK='# >>> hackathon-vps >>>'
END_MARK='# <<< hackathon-vps <<<'
CODE_RE='^[a-hj-km-np-z2-9]{4}-[a-hj-km-np-z2-9]{4}-[a-hj-km-np-z2-9]{4}$'

USER_ARG="${HACK_USER:-}"
CODE_ARG="${HACK_CODE:-}"
CHECK=0
PRINT=0

usage() {
  cat <<'EOT'
Usage: ./connect.sh -u NAME -c CODE [options]
  -u, --user NAME   Your name on the team (alvaro, bence, aranguren, hector). Default: $HACK_USER.
  -c, --code CODE   Your personal code (xxxx-xxxx-xxxx). Default: $HACK_CODE.
  --check           Only test whether `ssh hack` works now. Exit 0 if yes, 1 if not.
  --print           Only print the ssh config block and your public key.
  -h, --help        This help.
EOT
}

while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; USER_ARG="$2"; shift 2 ;;
    --user=*) USER_ARG="${1#--user=}"; shift ;;
    -c|--code) [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; CODE_ARG="$2"; shift 2 ;;
    --code=*) CODE_ARG="${1#--code=}"; shift ;;
    --check) CHECK=1; shift ;;
    --print) PRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

step() { printf '\n[%s] %s\n' "$1" "$2"; }
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }

# ---- 1. read hack.conf --------------------------------------------------------
step 1 "Reading hack.conf"
conf_get() { sed -n "s/^$1=//p" "$ROOT/hack.conf" | head -n1 | tr -d '\r'; }
[ -f "$ROOT/hack.conf" ] || { echo "hack.conf not found in $ROOT" >&2; exit 1; }
HOST_ALIAS="$(conf_get HOST_ALIAS)"
HOST_IP="$(conf_get HOST_IP)"
SSH_PORT="$(conf_get SSH_PORT)"
WEB_URL="$(conf_get WEB_URL)"
PROJECT_REPO="$(conf_get PROJECT_REPO)"
if [ -z "$HOST_ALIAS" ] || [ -z "$HOST_IP" ] || [ -z "$SSH_PORT" ] || [ -z "$WEB_URL" ]; then
  echo "hack.conf is incomplete (need HOST_ALIAS, HOST_IP, SSH_PORT, WEB_URL)." >&2
  exit 1
fi
if [ "$HOST_IP" = "__VPS_IP__" ] || [ "$WEB_URL" = "__WEB_URL__" ]; then
  echo "hack.conf still has placeholders (__VPS_IP__ / __WEB_URL__)." >&2
  echo "The admin has not published the server address yet. Ask Alvaro, then run: git pull" >&2
  exit 1
fi
WEB_URL="${WEB_URL%/}"
web_sub() { printf '%s' "$WEB_URL" | sed "s#^\\(https\\?://\\)#\\1$1.#"; }
echo "host alias $HOST_ALIAS -> $HOST_IP:$SSH_PORT, web $WEB_URL"

ssh_ok() { ssh -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=QUIET "$HOST_ALIAS" true >/dev/null 2>&1; }

if [ "$CHECK" -eq 1 ]; then
  if ssh_ok; then echo "OK: ssh $HOST_ALIAS works"; exit 0; fi
  echo "NOT OK: ssh $HOST_ALIAS does not work"
  exit 1
fi

# ---- 2. user and code ---------------------------------------------------------
step 2 "Checking your name and code"
[ -f "$ROOT/server/team.txt" ] || { echo "server/team.txt not found" >&2; exit 1; }
TEAM="$(awk 'NF && $1 !~ /^#/ {print $1}' "$ROOT/server/team.txt" | tr -d '\r')"
TEAM_LIST="$(printf '%s' "$TEAM" | tr '\n' ' ')"
USERNAME="$(norm "$USER_ARG")"
CODE="$(norm "$CODE_ARG")"
if [ -z "$USERNAME" ]; then
  if [ -t 0 ]; then
    read -r -p "Your name (${TEAM_LIST% }): " USERNAME
    USERNAME="$(norm "$USERNAME")"
  else
    echo "Missing -u NAME. Choose one of: $TEAM_LIST" >&2; exit 1
  fi
fi
if ! printf '%s\n' "$TEAM" | grep -qx -- "$USERNAME"; then
  echo "Unknown user '$USERNAME'. The team is: $TEAM_LIST" >&2
  exit 1
fi
if [ -z "$CODE" ]; then
  if [ -t 0 ]; then
    read -r -p "Your personal code (xxxx-xxxx-xxxx): " CODE
    CODE="$(norm "$CODE")"
  else
    echo "Missing -c CODE (the personal code Alvaro sent you)." >&2; exit 1
  fi
fi
if ! [[ "$CODE" =~ $CODE_RE ]]; then
  echo "The code does not look right. It has the form xxxx-xxxx-xxxx (letters and digits, no 0, o, 1, l, i)." >&2
  exit 1
fi
echo "user: $USERNAME"

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
  echo "--- public key ---"
  echo "$PUBKEY"
  exit 0
fi

# ---- 4. register the key with the server --------------------------------------
step 4 "Registering your key at $WEB_URL/join"
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
BODY_FILE="$(mktemp)"
RESP_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE" "$RESP_FILE"' EXIT
printf '{"user":"%s","code":"%s","pubkey":"%s"}' "$USERNAME" "$CODE" "$(json_escape "$PUBKEY")" > "$BODY_FILE"
HTTP="$(curl -sS --max-time 20 -o "$RESP_FILE" -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary "@$BODY_FILE" "$WEB_URL/join" 2>/dev/null || true)"
RESP="$(tr -d '\r\n' < "$RESP_FILE" 2>/dev/null || true)"
case "$HTTP" in
  200)
    if printf '%s' "$RESP" | grep -q '"added": *true'; then echo "key registered"; else echo "key was already registered"; fi ;;
  403) echo "Wrong user or code. Check the message Alvaro sent you and run again." >&2; exit 1 ;;
  429) echo "Too many failed tries from your network. Wait 10 minutes and run again." >&2; exit 1 ;;
  400) echo "The server rejected the request: $RESP" >&2; exit 1 ;;
  000|'')
    echo "Cannot reach $WEB_URL. Check your internet connection, or ask Alvaro whether the server is up" >&2
    echo "(the first HTTPS certificate can take about 30 s after setup)." >&2
    exit 1 ;;
  *) echo "Unexpected answer from the server (HTTP $HTTP): $RESP" >&2; exit 1 ;;
esac

# ---- 5. ssh config ------------------------------------------------------------
step 5 "Updating $SSH_DIR/config"
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

# ---- 6. test ------------------------------------------------------------------
step 6 "Testing ssh $HOST_ALIAS"
ok=0
for i in 1 2 3; do
  if ssh_ok; then ok=1; break; fi
  if [ "$i" -lt 3 ]; then echo "not yet (try $i of 3), retrying in 3 s..."; sleep 3; fi
done
if [ "$ok" -ne 1 ]; then
  echo "Your key is registered but ssh $HOST_ALIAS does not work from this computer." >&2
  echo "Try: ssh -v $HOST_ALIAS true  (a firewall or school/corporate network may block port $SSH_PORT; try a phone hotspot)." >&2
  exit 1
fi

cat <<EOF

You are connected as $USERNAME.
  ssh $HOST_ALIAS                  open a shell on the VPS

Web (login: user = $USERNAME, password = your code)
  $WEB_URL           landing page with all links
  $(web_sub code)      VS Code in the browser (live files, editor, terminal)
  $(web_sub files)     upload / download / share files
  $(web_sub stats)     CPU, RAM, disk, processes

Send files to the VPS:   ./send.sh <paths>   (Windows: .\\send.ps1 <paths>)  -> ~/hack/inbox/$USERNAME/
The team project:        ~/hack/project on the VPS (repo $PROJECT_REPO)
VS Code / Cursor:        Remote-SSH, connect to host "$HOST_ALIAS"
Shared terminal:         run 'pair' on the VPS
EOF
