#!/usr/bin/env bash
# Send files or folders to the shared VPS: ./send.sh <paths...>
# They land in ~/hack/inbox/<you>/ on the VPS (= /srv/hack/inbox/<you>/).
set -euo pipefail

[ $# -gt 0 ] || { echo "Usage: ./send.sh <path> [path...]" >&2; exit 2; }
CFG="$HOME/.ssh/config"
USERNAME=""
[ -f "$CFG" ] && USERNAME="$(awk '
  $0 == "# >>> hackathon-vps >>>" { inb = 1; next }
  $0 == "# <<< hackathon-vps <<<" { inb = 0 }
  inb && $1 == "User" { gsub(/\r/, "", $2); print $2; exit }' "$CFG")"
[ -n "$USERNAME" ] || { echo "No hack block in $CFG. Run ./connect.sh first." >&2; exit 1; }
for p in "$@"; do [ -e "$p" ] || { echo "Not found: $p" >&2; exit 1; }; done

scp -r -- "$@" "hack:hack/inbox/$USERNAME/"
echo "Sent. On the VPS: ~/hack/inbox/$USERNAME/   (browse it with Files or Code on the web page)"
