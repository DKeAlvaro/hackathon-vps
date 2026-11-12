#!/usr/bin/env bash
# Runs every minute from /etc/cron.d/hack-sync: update the repo, then sync members.
set -euo pipefail

{
  exec 9>/var/lock/hack-sync.lock
  flock -n 9 || exit 0
  cd /opt/hackathon-vps
  if git fetch -q; then
    git reset -q --hard origin/main
  fi
  # The brace group is parsed fully before running, so replacing this file
  # during the reset cannot corrupt the current run. fd 9 (the lock) is inherited.
  exec ./server/sync-members.sh
}
