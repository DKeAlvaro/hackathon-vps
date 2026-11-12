#!/usr/bin/env bash
# Create/update Linux accounts from keys/<username>.pub. Run as root, idempotent.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$REPO_DIR/keys"
LOG=/var/log/hack-sync.log
NAME_RE='^[a-z][a-z0-9-]{0,30}$'
KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( .*)?$'

if [ "$(id -u)" -ne 0 ]; then
  echo "sync-members.sh must run as root" >&2
  exit 1
fi

touch "$LOG"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

getent group team >/dev/null || { groupadd team; log "created group team"; }

declare -A wanted=()

# Print only the valid public key lines of a key file.
valid_keys() {
  local file="$1" line n=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ $KEY_RE ]] || continue
    n=$((n + 1))
    printf '%s\n' "$line" > "$tmp/one.pub"
    if ssh-keygen -l -f "$tmp/one.pub" >/dev/null 2>&1; then
      printf '%s\n' "$line"
    else
      log "skip invalid key line $n in $(basename "$file")"
    fi
  done < "$file"
}

shopt -s nullglob
for f in "$KEYS_DIR"/*.pub; do
  user="$(basename "$f" .pub)"

  if ! [[ "$user" =~ $NAME_RE ]]; then
    log "skip $(basename "$f"): invalid username"
    continue
  fi
  if [ "$user" = root ]; then
    log "skip $user: refused"
    continue
  fi

  if id "$user" >/dev/null 2>&1; then
    uid="$(id -u "$user")"
    if [ "$uid" -lt 1000 ]; then
      log "skip $user: existing system account (uid $uid)"
      continue
    fi
  fi

  valid_keys "$f" > "$tmp/keys.out"
  if [ ! -s "$tmp/keys.out" ]; then
    log "skip $user: no valid public key in file"
    continue
  fi

  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -c "hackathon member" "$user"
    log "created user $user"
  fi
  wanted["$user"]=1

  # Groups (only those that exist; docker may not exist before bootstrap finishes).
  current_groups=" $(id -nG "$user") "
  for g in team sudo docker; do
    if getent group "$g" >/dev/null && [[ "$current_groups" != *" $g "* ]]; then
      usermod -aG "$g" "$user"
      log "added $user to group $g"
    fi
  done

  home="$(getent passwd "$user" | cut -d: -f6)"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    log "skip $user: home directory missing"
    continue
  fi

  install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
  ak="$home/.ssh/authorized_keys"
  if [ -L "$ak" ] || ! cmp -s "$tmp/keys.out" "$ak"; then
    rm -f "$ak"
    install -m 600 -o "$user" -g "$user" "$tmp/keys.out" "$ak"
    log "installed authorized_keys for $user ($(wc -l < "$tmp/keys.out") key(s))"
  fi

  if [ -L "$home/hack" ]; then
    if [ "$(readlink "$home/hack")" != /srv/hack ]; then
      ln -sfn /srv/hack "$home/hack"
      chown -h "$user:$user" "$home/hack"
      log "fixed ~/hack symlink for $user"
    fi
  elif [ ! -e "$home/hack" ]; then
    ln -s /srv/hack "$home/hack"
    chown -h "$user:$user" "$home/hack"
    log "linked ~/hack for $user"
  fi
done

# Members whose key file is gone (or invalid): empty authorized_keys, keep user and home.
members="$(getent group team | cut -d: -f4 | tr ',' ' ')"
for user in $members; do
  [ -n "${wanted[$user]:-}" ] && continue
  [ "$user" = root ] && continue
  uid="$(id -u "$user" 2>/dev/null || echo 0)"
  [ "$uid" -ge 1000 ] || continue
  home="$(getent passwd "$user" | cut -d: -f6)"
  ak="$home/.ssh/authorized_keys"
  if [ -n "$home" ] && [ -s "$ak" ] && [ ! -L "$ak" ]; then
    : > "$ak"
    log "revoked $user: key file removed, authorized_keys emptied"
  fi
done
