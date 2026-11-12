#!/usr/bin/env bash
# Set up the shared hackathon VPS. Run as root on a fresh Ubuntu 24.04:
#   bash /opt/hackathon-vps/server/bootstrap.sh
# or, the first time:
#   curl -fsSL https://raw.githubusercontent.com/DKeAlvaro/hackathon-vps/main/server/bootstrap.sh | bash
# Idempotent: safe to run again (also how you apply updates, new people, rotated codes).
# Env: HACK_DOMAIN overrides the web hostname (default <ip-with-dashes>.sslip.io).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
REPO_URL="https://github.com/DKeAlvaro/hackathon-vps.git"
REPO_DIR=/opt/hackathon-vps
PROJECT_REPO="DKeAlvaro/hackathon"
NAME_RE='^[a-z][a-z0-9-]{0,30}$'
WARNINGS=()

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARNINGS+=("$*"); }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---- run from the clone in /opt/hackathon-vps ---------------------------------
here=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ "$here" != "$REPO_DIR/server" ]; then
  say "Using the clone in $REPO_DIR"
  command -v git >/dev/null || { apt-get update -y; apt-get install "${APT_OPTS[@]}" git ca-certificates; }
  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull -q --ff-only || echo "could not update $REPO_DIR, using it as is" >&2
  else
    git clone "$REPO_URL" "$REPO_DIR"
  fi
  exec bash "$REPO_DIR/server/bootstrap.sh" "$@"
fi
SERVER_DIR="$REPO_DIR/server"
TEAM_FILE="$SERVER_DIR/team.txt"
chmod +x "$SERVER_DIR"/*.sh "$SERVER_DIR"/join/join.py 2>/dev/null || true

# team.txt -> TEAM_USERS (names) and TEAM_DISPLAY[name]
TEAM_USERS=()
declare -A TEAM_DISPLAY=()
while read -r u display || [ -n "${u:-}" ]; do
  case "${u:-}" in ""|"#"*) continue ;; esac
  if ! [[ "$u" =~ $NAME_RE ]] || [ "$u" = root ]; then
    warn "team.txt: ignoring invalid name '$u'"; continue
  fi
  TEAM_USERS+=("$u")
  TEAM_DISPLAY[$u]="${display:-$u}"
done < <(tr -d '\r' < "$TEAM_FILE")
[ "${#TEAM_USERS[@]}" -gt 0 ] || { echo "server/team.txt has no users" >&2; exit 1; }

say "apt update/upgrade and base packages"
apt-get update -y
apt-get upgrade "${APT_OPTS[@]}"
apt-get install "${APT_OPTS[@]}" git curl wget tmux htop btop jq unzip zip build-essential \
  python3 python3-pip python3-venv pipx ripgrep fd-find ufw fail2ban acl ca-certificates gnupg openssh-client
# Ubuntu names the fd binary fdfind; add the usual name.
if command -v fdfind >/dev/null && ! command -v fd >/dev/null; then
  ln -s "$(command -v fdfind)" /usr/local/bin/fd
fi

say "Node.js 22 LTS"
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" != 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install "${APT_OPTS[@]}" nodejs
fi
node --version

say "Claude Code and Codex CLIs"
if ! npm i -g @anthropic-ai/claude-code @openai/codex; then
  warn "npm install of claude-code/codex failed; retry later: npm i -g @anthropic-ai/claude-code @openai/codex"
fi

# shellcheck disable=SC1091
. /etc/os-release

say "Docker Engine + compose plugin"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install "${APT_OPTS[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

say "GitHub CLI"
if ! command -v gh >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -y
  apt-get install "${APT_OPTS[@]}" gh
fi

say "uv"
if ! command -v uv >/dev/null; then
  if ! curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh; then
    warn "uv install failed; retry: curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh"
  fi
fi

say "Swap"
if [ -z "$(swapon --show --noheadings)" ]; then
  if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "swap already present"
fi

say "Timezone"
timedatectl set-timezone Europe/Amsterdam

say "Group team, passwordless sudo, shared directory"
getent group team >/dev/null || groupadd team
getent group docker >/dev/null || groupadd docker
tmpf="$(mktemp)"
echo '%team ALL=(ALL) NOPASSWD:ALL' > "$tmpf"
if visudo -cf "$tmpf" >/dev/null; then
  install -m 0440 -o root -g root "$tmpf" /etc/sudoers.d/team
else
  warn "sudoers file for team failed validation, not installed"
fi
rm -f "$tmpf"

mkdir -p /srv/hack /srv/hack/.tmux /srv/hack/inbox
chown root:team /srv/hack /srv/hack/.tmux /srv/hack/inbox
chmod 2775 /srv/hack /srv/hack/.tmux /srv/hack/inbox
setfacl -R -m g:team:rwX /srv/hack
setfacl -R -d -m g:team:rwX /srv/hack
if [ ! -f /srv/hack/README.md ]; then
  cat > /srv/hack/README.md <<'EOF'
# Shared hackathon workspace

This folder (/srv/hack, also ~/hack) is shared by the whole team.

- project/   live checkout of main (read-only by convention: reset to main on every push). Run the shared
             demo from here. Do not edit it; code on your own computer and push to origin.
- project.git/  central git repo (origin of everyone's local clone: hack:/srv/hack/project.git).
             Pushes to main update project/ and are mirrored to GitHub DKeAlvaro/hackathon.
- Nobody runs coding agents on this server (6 GB RAM): agents run on each person's own machine.
- inbox/<you>/  files sent from your laptop with send.sh / send.ps1
- kit-agentes/  skills and AGENTS.md template for coding agents
- Everyone in group `team` can read and write everything here (setgid + default ACLs).
- Shared terminal: run `pair` (or `pair <name>`). Detach with Ctrl-b d.
- Open ports for your apps: 3000-3999, 5000-5999, 8000-8999 (plus 80 and 443).
  Bind to 0.0.0.0, then open http://<server-ip>:<port>.
- Docker-published ports (-p 8080:80) bypass ufw. Use -p 127.0.0.1:8080:80 to keep one private.
- Never commit secrets (API keys, .env files).
- Check `free -h` before heavy builds: RAM is shared.
EOF
fi
chown root:team /srv/hack/README.md
chmod 664 /srv/hack/README.md

say "Team users, personal codes, admin key"
mkdir -p /etc/hack
chown root:team /etc/hack
chmod 750 /etc/hack

for u in "${TEAM_USERS[@]}"; do
  if id "$u" >/dev/null 2>&1; then
    uid="$(id -u "$u")"
    if [ "$uid" -lt 1000 ] || [ "$uid" -eq 0 ]; then
      warn "$u is a system account (uid $uid): not touching it"; continue
    fi
    usermod -aG team,sudo,docker "$u"
  else
    useradd -m -s /bin/bash -G team,sudo,docker "$u"
  fi
  home="$(getent passwd "$u" | cut -d: -f6)"
  ln -sfn /srv/hack "$home/hack"
  chown -h "$u:$u" "$home/hack"
  gc="$home/.gitconfig"
  if [ -z "$(git config --file "$gc" --get user.name 2>/dev/null || true)" ]; then
    git config --file "$gc" user.name "${TEAM_DISPLAY[$u]}"
    git config --file "$gc" user.email "$u@hackathon.local"
  fi
  [ -n "$(git config --file "$gc" --get init.defaultBranch 2>/dev/null || true)" ] || git config --file "$gc" init.defaultBranch main
  chown "$u:$u" "$gc"
  install -d -o "$u" -g team -m 2775 "/srv/hack/inbox/$u"
  install -d -o "$u" -g "$u" -m 700 "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  chown "$u:$u" "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
done

# Codes: generated once; people added to team.txt later get a line appended.
gen_code() {
  python3 -c 'import secrets
a = "abcdefghjkmnpqrstuvwxyz23456789"
c = "".join(secrets.choice(a) for _ in range(12))
print("-".join(c[i:i + 4] for i in (0, 4, 8)))'
}
CODES=/etc/hack/codes
[ -f "$CODES" ] || install -m 600 -o root -g root /dev/null "$CODES"
for u in "${TEAM_USERS[@]}"; do
  if ! awk -v u="$u" '$1 == u { f = 1 } END { exit !f }' "$CODES"; then
    printf '%s %s\n' "$u" "$(gen_code)" >> "$CODES"
  fi
done
chown root:root "$CODES"
chmod 600 "$CODES"

# Admin key (Alvaro): root and alvaro.
ADMIN_PUB="$SERVER_DIR/admin.pub"
ADMIN_KEY_OK=0
if [ -s "$ADMIN_PUB" ] && ssh-keygen -l -f "$ADMIN_PUB" >/dev/null 2>&1; then
  ADMIN_KEY_OK=1
  admin_line="$(grep -E '^(ssh-|ecdsa-|sk-)' "$ADMIN_PUB" | head -n1 | tr -d '\r')"
  admin_blob="$(printf '%s' "$admin_line" | awk '{print $2}')"
  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  grep -qF "$admin_blob" /root/.ssh/authorized_keys || printf '%s\n' "$admin_line" >> /root/.ssh/authorized_keys
  if id alvaro >/dev/null 2>&1; then
    ak="$(getent passwd alvaro | cut -d: -f6)/.ssh/authorized_keys"
    grep -qF "$admin_blob" "$ak" || printf '%s\n' "$admin_line" >> "$ak"
    chown alvaro:alvaro "$ak"
    chmod 600 "$ak"
  fi
else
  warn "server/admin.pub missing or invalid: admin key not installed"
fi

say "Deploy key, central project repo and live checkout ($PROJECT_REPO)"
DEPLOY_KEY=/etc/hack/deploy_key
if [ ! -f "$DEPLOY_KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "hack-vps" -f "$DEPLOY_KEY"
fi
chown root:team "$DEPLOY_KEY"
chmod 640 "$DEPLOY_KEY"
chown root:root "$DEPLOY_KEY.pub"
chmod 644 "$DEPLOY_KEY.pub"
touch /etc/ssh/ssh_known_hosts
if ! grep -q '^github.com ' /etc/ssh/ssh_known_hosts; then
  ssh-keyscan -T 10 github.com 2>/dev/null >> /etc/ssh/ssh_known_hosts \
    || warn "ssh-keyscan github.com failed; clone over ssh may ask to trust the host"
fi
GIT_SSH="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes"
BARE=/srv/hack/project.git
LIVE=/srv/hack/project
MIRROR_LOG=/srv/hack/.mirror.log
PROJECT_STATUS="missing"
LIVE_STATUS="missing"
if [ ! -f "$BARE/HEAD" ]; then
  # Run as alvaro: OpenSSH refuses a group-readable key only when the key is owned by the caller.
  if runuser -u alvaro -- env GIT_SSH_COMMAND="$GIT_SSH -o BatchMode=yes" GIT_TERMINAL_PROMPT=0 \
       git clone --bare "git@github.com:$PROJECT_REPO.git" "$BARE"; then
    PROJECT_STATUS="created from GitHub"
  else
    PROJECT_STATUS="clone failed"
    warn "could not clone $PROJECT_REPO into $BARE: add the deploy key (command in the summary) and re-run bootstrap"
  fi
else
  PROJECT_STATUS="present"
fi
if [ -f "$BARE/HEAD" ]; then
  git -C "$BARE" symbolic-ref HEAD refs/heads/main
  git -C "$BARE" config core.sharedRepository group
  git -C "$BARE" remote remove origin 2>/dev/null || true
  if git -C "$BARE" remote get-url github >/dev/null 2>&1; then
    git -C "$BARE" remote set-url github "git@github.com:$PROJECT_REPO.git"
  else
    git -C "$BARE" remote add github "git@github.com:$PROJECT_REPO.git"
  fi
  git -C "$BARE" config core.sshCommand "$GIT_SSH"
  # Hooks: guard main (no force-push, no delete), update the live checkout, mirror to GitHub.
  install -d -m 755 "$BARE/hooks"
  install -m 755 "$SERVER_DIR/git/pre-receive" "$BARE/hooks/pre-receive"
  install -m 755 "$SERVER_DIR/git/post-receive" "$BARE/hooks/post-receive"
  touch "$MIRROR_LOG"
  # Live checkout of main: a normal clone of the bare repo.
  if [ ! -d "$LIVE/.git" ]; then
    if [ -e "$LIVE" ] && [ -n "$(ls -A "$LIVE" 2>/dev/null)" ]; then
      warn "$LIVE exists and is not a git clone: move it away and re-run bootstrap"
      LIVE_STATUS="blocked"
    elif runuser -u alvaro -- git clone -q -b main "$BARE" "$LIVE"; then
      LIVE_STATUS="cloned"
    else
      LIVE_STATUS="clone failed"
      warn "could not clone $BARE into $LIVE"
    fi
  else
    # Older installs cloned from GitHub: point origin at the central repo.
    git -C "$LIVE" remote set-url origin "$BARE"
    git -C "$LIVE" config --unset core.sshCommand 2>/dev/null || true
    LIVE_STATUS="present"
  fi
  if [ -d "$LIVE/.git" ]; then
    git -C "$LIVE" config core.sharedRepository group
    git -C "$LIVE" checkout -q main 2>/dev/null || true
  fi
  for d in "$BARE" "$LIVE"; do
    [ -e "$d" ] || continue
    chgrp -R team "$d"
    chmod -R g+rwX "$d"
    find "$d" -type d -exec chmod g+s {} +
    setfacl -R -m g:team:rwX "$d"
    setfacl -R -d -m g:team:rwX "$d"
  done
  chgrp team "$MIRROR_LOG"
  chmod 664 "$MIRROR_LOG"
fi

# gruia agent kit (skills for Claude Code/Codex + AGENTS.md template), copied into projects on demand.
if [ ! -d /srv/hack/kit-agentes/.git ]; then
  git clone -q --depth 1 https://github.com/gruia-app/skills.git /srv/hack/kit-agentes \
    || warn "could not clone gruia-app/skills"
fi
if [ -d /srv/hack/kit-agentes ]; then
  chgrp -R team /srv/hack/kit-agentes
  setfacl -R -m g:team:rwX /srv/hack/kit-agentes
fi
setfacl -R -m g:team:rwX /srv/hack
setfacl -R -d -m g:team:rwX /srv/hack

say "pair helper, umask, git safe.directory"
cat > /usr/local/bin/pair <<'EOF'
#!/usr/bin/env bash
# pair [name]: attach to (or create) a shared tmux session any team member can join.
set -euo pipefail
name="${1:-main}"
case "$name" in
  ""|*[!A-Za-z0-9_-]*) echo "Session name: letters, digits, - and _ only" >&2; exit 1 ;;
esac
dir=/srv/hack/.tmux
sock="$dir/$name"
umask 002
mkdir -p "$dir" 2>/dev/null || true
if ! tmux -S "$sock" has-session -t "$name" 2>/dev/null; then
  tmux -S "$sock" new-session -d -s "$name" -c /srv/hack
fi
# tmux >= 3.3 only lets other users connect after server-access; only the owner can grant it.
if [ -O "$sock" ]; then
  for u in $(getent group team | cut -d: -f4 | tr ',' ' '); do
    [ "$u" = "$(id -un)" ] || tmux -S "$sock" server-access -a -w "$u" 2>/dev/null || true
  done
fi
chgrp team "$sock" 2>/dev/null || true
chmod 660 "$sock" 2>/dev/null || true
exec tmux -S "$sock" attach-session -t "$name"
EOF
chmod 755 /usr/local/bin/pair

cat > /etc/profile.d/hack.sh <<'EOF'
# Shared workspace: files created by team members are group-writable.
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx team; then
  umask 002
fi
EOF
chmod 644 /etc/profile.d/hack.sh
git config --system safe.directory '*'

# ---- web command center --------------------------------------------------------
say "Public hostname"
BASE="${HACK_DOMAIN:-}"
PUBLIC_IP=""
if [ -z "$BASE" ]; then
  PUBLIC_IP="$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$PUBLIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    BASE="${PUBLIC_IP//./-}.sslip.io"
  else
    PUBLIC_IP=""
    [ -s /etc/hack/domain ] && BASE="$(cat /etc/hack/domain)"
  fi
fi
if [ -n "$BASE" ] && ! [[ "$BASE" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  warn "invalid domain '$BASE': web tools skipped"
  BASE=""
fi
if [ -n "$BASE" ]; then
  echo "$BASE" > /etc/hack/domain
  echo "BASE = $BASE"
else
  warn "could not detect the public IPv4 (set HACK_DOMAIN=<name> and re-run): web tools skipped"
fi

say "hackweb service user"
if ! id hackweb >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/hackweb --shell /bin/bash -g team hackweb
fi
usermod -aG team hackweb
mkdir -p /var/lib/hackweb
chown hackweb:team /var/lib/hackweb
chmod 750 /var/lib/hackweb
if [ -z "$(git config --file /var/lib/hackweb/.gitconfig --get user.name 2>/dev/null || true)" ]; then
  git config --file /var/lib/hackweb/.gitconfig user.name "Hackathon Web"
  git config --file /var/lib/hackweb/.gitconfig user.email "web@hackathon.local"
  git config --file /var/lib/hackweb/.gitconfig init.defaultBranch main
  chown hackweb:team /var/lib/hackweb/.gitconfig
fi

say "code-server (https://code.BASE)"
if ! command -v code-server >/dev/null; then
  curl -fsSL https://code-server.dev/install.sh | sh \
    || warn "code-server install failed; retry: curl -fsSL https://code-server.dev/install.sh | sh"
fi
CS_USER_DIR=/var/lib/hackweb/code-server/data
install -d -o hackweb -g team -m 750 /var/lib/hackweb/code-server /var/lib/hackweb/code-server/data \
  /var/lib/hackweb/code-server/extensions "$CS_USER_DIR/User"
if [ ! -f "$CS_USER_DIR/User/settings.json" ]; then
  cat > "$CS_USER_DIR/User/settings.json" <<'EOF'
{
  "workbench.startupEditor": "none",
  "workbench.colorTheme": "Default Dark Modern",
  "security.workspace.trust.enabled": false,
  "telemetry.telemetryLevel": "off",
  "files.exclude": {
    "**/node_modules": true,
    "**/.venv": true,
    "**/__pycache__": true,
    "**/dist": true,
    "**/build": true,
    "**/.next": true
  },
  "files.watcherExclude": {
    "**/node_modules/**": true,
    "**/.venv/**": true,
    "**/__pycache__/**": true,
    "**/dist/**": true,
    "**/build/**": true,
    "**/.next/**": true,
    "**/.git/objects/**": true
  }
}
EOF
  chown hackweb:team "$CS_USER_DIR/User/settings.json"
fi
cat > /etc/systemd/system/hack-code.service <<'EOF'
[Unit]
Description=code-server (shared VS Code in the browser)
After=network.target

[Service]
User=hackweb
Group=team
UMask=0002
Environment=HOME=/var/lib/hackweb
WorkingDirectory=/srv/hack
ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8790 --auth none --disable-telemetry --disable-update-check --user-data-dir /var/lib/hackweb/code-server/data --extensions-dir /var/lib/hackweb/code-server/extensions /srv/hack
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

say "File Browser (https://files.BASE)"
FB=/usr/local/bin/filebrowser
if [ ! -x "$FB" ]; then
  fbtmp="$(mktemp -d)"
  if curl -fsSL https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz -o "$fbtmp/fb.tgz" \
     && tar -xzf "$fbtmp/fb.tgz" -C "$fbtmp" filebrowser; then
    install -m 755 "$fbtmp/filebrowser" "$FB"
  else
    warn "filebrowser download failed; re-run bootstrap later"
  fi
  rm -rf "$fbtmp"
fi
FB_DB=/var/lib/filebrowser/filebrowser.db
install -d -o hackweb -g team -m 750 /var/lib/filebrowser
if [ -x "$FB" ]; then
  systemctl stop hack-files 2>/dev/null || true
  fb() { runuser -u hackweb -- "$FB" -d "$FB_DB" "$@"; }
  [ -f "$FB_DB" ] || fb config init >/dev/null
  fb config set -a 127.0.0.1 -p 8791 -r /srv/hack -b "" --auth.method=proxy --auth.header=X-Remote-User >/dev/null \
    || warn "filebrowser config set failed"
  existing_fb="$(fb users ls 2>/dev/null || true)"
  for u in "${TEAM_USERS[@]}"; do
    if ! printf '%s\n' "$existing_fb" | awk '{print $2}' | grep -qx "$u"; then
      pw="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
      adm=""
      [ "$u" = alvaro ] && adm="--perm.admin"
      # shellcheck disable=SC2086
      fb users add "$u" "$pw" $adm --perm.create --perm.rename --perm.modify --perm.delete --perm.share --perm.download >/dev/null \
        || warn "filebrowser: could not add user $u"
    fi
  done
fi
cat > /etc/systemd/system/hack-files.service <<'EOF'
[Unit]
Description=File Browser (shared upload/download)
After=network.target

[Service]
User=hackweb
Group=team
UMask=0002
ExecStart=/usr/local/bin/filebrowser -d /var/lib/filebrowser/filebrowser.db
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

say "Glances (https://stats.BASE)"
GLANCES=""
if ! command -v glances >/dev/null; then
  if command -v uv >/dev/null; then
    mkdir -p /opt/uv-tools
    export UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin
    uv tool install 'glances[web,containers]' >/dev/null 2>&1 \
      || uv tool install 'glances[web]' >/dev/null 2>&1 || true
    unset UV_TOOL_DIR UV_TOOL_BIN_DIR
  fi
  if ! command -v glances >/dev/null; then
    apt-get install "${APT_OPTS[@]}" glances python3-bottle python3-jinja2 \
      || warn "glances install failed (uv and apt)"
  fi
fi
GLANCES="$(command -v glances || true)"
cat > /etc/systemd/system/hack-stats.service <<EOF
[Unit]
Description=Glances web UI (machine stats)
After=network.target docker.service

[Service]
ExecStart=${GLANCES:-/usr/local/bin/glances} -w --bind 127.0.0.1 --port 8793
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

say "Join service (127.0.0.1:8792)"
cat > /etc/systemd/system/hack-join.service <<EOF
[Unit]
Description=Hackathon join endpoint (installs SSH keys for team members)
After=network.target

[Service]
ExecStart=/usr/bin/python3 $SERVER_DIR/join/join.py
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
for s in hack-code hack-files hack-stats hack-join; do
  systemctl enable "$s" >/dev/null 2>&1 || true
  systemctl restart "$s" || warn "service $s failed to start (journalctl -u $s)"
done
rm -f /etc/cron.d/hack-sync   # leftover from the old key-sync model

say "Caddy (HTTPS reverse proxy)"
if ! command -v caddy >/dev/null; then
  install -m 0755 -d /usr/share/keyrings
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install "${APT_OPTS[@]}" caddy || warn "caddy install failed"
fi

CADDY_STATUS="skipped"
if [ -n "$BASE" ] && command -v caddy >/dev/null; then
  install -d -m 755 /var/www/hack
  sed "s/__BASE__/$BASE/g" "$SERVER_DIR/web/index.html" > /var/www/hack/index.html
  chmod 644 /var/www/hack/index.html

  render_caddyfile() {
    printf '# Generated by bootstrap.sh, do not edit by hand.\n'
    printf '(auth) {\n\tbasic_auth {\n'
    while read -r u code || [ -n "${u:-}" ]; do
      [ -n "${u:-}" ] && [ -n "${code:-}" ] || continue
      printf '%s\n' "${TEAM_USERS[@]}" | grep -qx -- "$u" || continue   # only current team members
      printf '\t\t%s %s\n' "$u" "$(caddy hash-password --plaintext "$code" </dev/null)"
    done < "$CODES"
    printf '\t}\n}\n\n'
    printf '(proxy) {\n\treverse_proxy 127.0.0.1:{args[0]} {\n\t\theader_up X-Remote-User {http.auth.user.id}\n\t}\n}\n\n'
    cat <<EOF
$BASE {
	@join path /join /join/*
	handle @join {
		reverse_proxy 127.0.0.1:8792
	}
	handle {
		import auth
		root * /var/www/hack
		file_server
	}
}

code.$BASE {
	import auth
	import proxy 8790
}

files.$BASE {
	import auth
	import proxy 8791
}

stats.$BASE {
	import auth
	import proxy 8793
}
EOF
  }

  cf_tmp="$(mktemp)"
  render_caddyfile > "$cf_tmp"
  if caddy validate --config "$cf_tmp" --adapter caddyfile >/dev/null 2>&1; then
    install -m 644 -o root -g root "$cf_tmp" /etc/caddy/Caddyfile
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy || warn "caddy failed to start (journalctl -u caddy)"
    CADDY_STATUS="ok"
  else
    warn "generated Caddyfile did not validate; /etc/caddy/Caddyfile left unchanged"
    CADDY_STATUS="invalid config"
  fi
  rm -f "$cf_tmp"
fi

say "MOTD"
cat > /etc/update-motd.d/99-hack <<'EOF'
#!/bin/sh
base="$(cat /etc/hack/domain 2>/dev/null)"
echo
echo "  Hackathon VPS"
echo "  Shared folder : ~/hack  (/srv/hack)   live main: ~/hack/project"
echo "  Shared tmux   : run 'pair'  (or 'pair <name>')"
if [ -n "$base" ]; then
  echo "  Web           : https://$base"
  echo "                  https://code.$base   https://files.$base   https://stats.$base"
fi
echo "  Online now    : $(who | awk '{print $1}' | sort -u | tr '\n' ' ')"
echo "  Open ports    : 3000-3999, 5000-5999, 8000-8999, 80, 443"
echo
EOF
chmod 755 /etc/update-motd.d/99-hack

say "fail2ban"
mkdir -p /etc/fail2ban/jail.d
printf '[sshd]\nenabled = true\n' > /etc/fail2ban/jail.d/hack.local
systemctl enable fail2ban
systemctl restart fail2ban

say "Firewall (ufw)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3000:3999/tcp
ufw allow 5000:5999/tcp
ufw allow 8000:8999/tcp
ufw --force enable

say "SSH hardening"
# Never disable passwords unless a key login for root exists (the admin key was installed above).
have_key=0
if [ -s /root/.ssh/authorized_keys ] && grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys; then have_key=1; fi
if [ "$have_key" -eq 1 ]; then
  cat > /etc/ssh/sshd_config.d/10-hack.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
ClientAliveInterval 30
ClientAliveCountMax 6
EOF
  if sshd -t; then
    systemctl reload ssh
  else
    rm -f /etc/ssh/sshd_config.d/10-hack.conf
    warn "sshd config test failed; hardening drop-in removed"
  fi
else
  warn "no key in /root/.ssh/authorized_keys; SSH hardening skipped (would lock you out). Add a key and re-run."
fi

# ---- summary --------------------------------------------------------------------
say "Summary"
if [ -n "$BASE" ]; then
  echo "Web (first HTTPS certificate can take ~30 s; login = user name + personal code):"
  echo "  https://$BASE"
  echo "  https://code.$BASE    VS Code in the browser (live files, editor, terminal)"
  echo "  https://files.$BASE   File Browser"
  echo "  https://stats.$BASE   Glances"
  echo "Fill in hack.conf in the repo, commit and push:"
  echo "  HOST_IP=${PUBLIC_IP:-<server ip>}"
  echo "  WEB_URL=https://$BASE"
fi
echo
echo "Personal codes (/etc/hack/codes), send each person their own line:"
awk '{ printf "  %-12s %s\n", $1, $2 }' "$CODES"
echo
echo "Deploy key for $PROJECT_REPO ($DEPLOY_KEY): public key"
cat "$DEPLOY_KEY.pub"
echo "Admin command (on a machine where gh is logged in as the repo owner; hack-vps.pub holds the line above):"
echo "  gh repo deploy-key add hack-vps.pub --repo $PROJECT_REPO --allow-write --title hack-vps"
echo "  e.g.: ssh root@${PUBLIC_IP:-<server ip>} cat $DEPLOY_KEY.pub > hack-vps.pub"
echo "Central repo   : $PROJECT_STATUS ($BARE)"
if [ -f "$BARE/HEAD" ]; then
  echo "  branches      : $(git -C "$BARE" for-each-ref --format='%(refname:short)' refs/heads | tr '
' ' ')"
  echo "  mirror remote : $(git -C "$BARE" remote get-url github) (log: $MIRROR_LOG)"
fi
echo "Live checkout   : $LIVE_STATUS ($LIVE)$( [ -d "$LIVE/.git" ] && echo " at $(git -C "$LIVE" rev-parse --short HEAD 2>/dev/null) on $(git -C "$LIVE" rev-parse --abbrev-ref HEAD 2>/dev/null)" )"
echo
echo "Shared dir : /srv/hack (root:team 2775, default ACL g:team:rwX)"
echo "Members    : $(getent group team | cut -d: -f4)"
echo "Node       : $(node --version), Docker: $(docker --version 2>/dev/null || echo missing)"
echo "ufw        : $(ufw status | head -1)"
echo "Services   :"
for s in hack-code hack-files hack-stats hack-join caddy fail2ban; do
  printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"
done
echo "Caddy config: $CADDY_STATUS"
[ "$ADMIN_KEY_OK" -eq 1 ] || echo "Admin key  : NOT installed"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo "Warnings:"
  printf '  - %s\n' "${WARNINGS[@]}"
fi
echo "Done."
