#!/usr/bin/env bash
# One-time setup of the shared hackathon VPS. Run as root on a fresh Ubuntu 24.04:
#   curl -fsSL https://raw.githubusercontent.com/DKeAlvaro/hackathon-vps/main/server/bootstrap.sh | sudo bash
# Idempotent: safe to run again.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
REPO_URL="https://github.com/DKeAlvaro/hackathon-vps.git"
REPO_DIR=/opt/hackathon-vps
WARNINGS=()

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; WARNINGS+=("$*"); }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

say "apt update/upgrade and base packages"
apt-get update -y
apt-get upgrade "${APT_OPTS[@]}"
apt-get install "${APT_OPTS[@]}" git curl wget tmux htop btop jq unzip zip build-essential \
  python3 python3-pip python3-venv pipx ripgrep fd-find ufw fail2ban acl ca-certificates gnupg
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

mkdir -p /srv/hack /srv/hack/.tmux
chown root:team /srv/hack /srv/hack/.tmux
chmod 2775 /srv/hack /srv/hack/.tmux
setfacl -R -m g:team:rwX /srv/hack
setfacl -R -d -m g:team:rwX /srv/hack
if [ ! -f /srv/hack/README.md ]; then
  cat > /srv/hack/README.md <<'EOF'
# Shared hackathon workspace

This folder (/srv/hack, also ~/hack) is shared by the whole team.

- Put every project in its own folder here: `cd ~/hack && git clone ...` or `mkdir my-project`.
- Everyone in group `team` can read and write everything here (setgid + default ACLs).
- Shared terminal: run `pair` (or `pair <name>`) to attach to a tmux session everyone can join.
  Detach with Ctrl-b d. Long jobs belong in tmux so they survive disconnects.
- Open ports for your apps: 3000-3999, 5000-5999, 8000-8999 (plus 80 and 443).
  Bind to 0.0.0.0, then open http://<server-ip>:<port>.
- Docker-published ports (-p 8080:80) bypass ufw: they are reachable from the internet
  regardless of the firewall. Bind to 127.0.0.1 (-p 127.0.0.1:8080:80) if it should stay private.
- Do not commit secrets (API keys, .env files) to public repos.
- Check `free -h` before heavy builds: RAM is shared.
EOF
fi
chown root:team /srv/hack/README.md
chmod 664 /srv/hack/README.md

# gruia agent kit (skills for Claude Code/Codex + AGENTS.md template), copied into projects on demand.
if [ ! -d /srv/hack/kit-agentes/.git ]; then
  git clone -q --depth 1 https://github.com/gruia-app/skills.git /srv/hack/kit-agentes \
    || echo "WARNING: could not clone gruia-app/skills" >&2
fi
if [ -d /srv/hack/kit-agentes ]; then
  chgrp -R team /srv/hack/kit-agentes
  setfacl -R -m g:team:rwX /srv/hack/kit-agentes
fi

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

say "MOTD"
cat > /etc/update-motd.d/99-hack <<'EOF'
#!/bin/sh
cache=/var/cache/hack-public-ip
if [ ! -s "$cache" ] || [ -n "$(find "$cache" -mmin +60 2>/dev/null)" ]; then
  ip="$(curl -s --max-time 2 https://api.ipify.org 2>/dev/null)"
  [ -n "$ip" ] && echo "$ip" > "$cache"
fi
ip="$(cat "$cache" 2>/dev/null)"
echo
echo "  Hackathon VPS${ip:+ - public IP $ip}"
echo "  Shared folder : ~/hack  (/srv/hack)"
echo "  Shared tmux   : run 'pair'  (or 'pair <name>')"
echo "  Online now    : $(who | awk '{print $1}' | sort -u | tr '\n' ' ')"
echo "  Open ports    : 3000-3999, 5000-5999, 8000-8999, 80, 443"
echo
EOF
chmod 755 /etc/update-motd.d/99-hack

say "Repo clone, cron sync, first sync"
if [ ! -d "$REPO_DIR/.git" ]; then
  git clone "$REPO_URL" "$REPO_DIR"
fi
chmod +x "$REPO_DIR"/server/*.sh
echo '* * * * * root /opt/hackathon-vps/server/cron-sync.sh >>/var/log/hack-sync.log 2>&1' > /etc/cron.d/hack-sync
chmod 644 /etc/cron.d/hack-sync
"$REPO_DIR/server/sync-members.sh"

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
# Never disable passwords unless at least one key login exists (avoids locking everyone out).
have_key=0
for ak in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
  if [ -s "$ak" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$ak"; then have_key=1; fi
done
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
  warn "no authorized_keys found anywhere; SSH hardening skipped (would lock you out). Add a key and re-run."
fi

say "Summary"
echo "Shared dir : /srv/hack (root:team 2775, default ACL g:team:rwX)"
echo "Members    : $(getent group team | cut -d: -f4)"
echo "Sync log   : /var/log/hack-sync.log (cron every minute)"
echo "Node       : $(node --version), Docker: $(docker --version 2>/dev/null || echo missing)"
echo "ufw        : $(ufw status | head -1)"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo "Warnings:"
  printf '  - %s\n' "${WARNINGS[@]}"
fi
echo "Done."
