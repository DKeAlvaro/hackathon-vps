# hackathon-vps

One shared Ubuntu 24.04 server for our 72-hour hackathon. Everyone gets their own account (SSH key only)
and works in the same shared folder.

Server: __VPS_SPECS__

## The 30-second version

Open your coding agent (Claude Code, Codex, Cursor, ...) and tell it:

> clone https://github.com/DKeAlvaro/hackathon-vps and connect me to the VPS

The agent reads `AGENTS.md` and does everything. When it is done, `ssh hack` works.

## Manual setup (no agent)

macOS / Linux / Git Bash:

```
git clone https://github.com/DKeAlvaro/hackathon-vps.git && cd hackathon-vps
./connect.sh -u yourname
./connect.sh --wait 10
```

Windows PowerShell:

```
git clone https://github.com/DKeAlvaro/hackathon-vps.git; cd hackathon-vps
powershell -ExecutionPolicy Bypass -File .\connect.ps1 -User yourname
powershell -ExecutionPolicy Bypass -File .\connect.ps1 -Wait 10
```

`yourname` is lowercase letters, digits and hyphens, starting with a letter.

## How to join

Access is a file: `keys/<yourname>.pub` with your public SSH key. The connect script creates the key
(`~/.ssh/hack_ed25519`), adds a `hack` entry to `~/.ssh/config`, and opens a pull request adding the file
(or pushes it straight to `main` if you have push access). Once the admin merges it, your account exists
within about a minute. No `gh`? The script prints your public key; send it to the admin or open the PR on
github.com yourself.

## On the server

- Shared folder: `~/hack` (= `/srv/hack`), readable and writable by everyone on the team.
- `pair` opens a tmux session everyone can join (`pair <name>` for more sessions).
- Installed: git, tmux, htop/btop, jq, ripgrep, fd, build tools, Python 3 + pip/venv/pipx/uv,
  Node.js 22, Docker + compose, gh, Claude Code, Codex.
- Open ports: 22, 80, 443, 3000-3999, 5000-5999, 8000-8999. Docker-published ports bypass the firewall.
- You have passwordless `sudo` and are in the `docker` group. Be kind to the shared RAM.
- VS Code / Cursor: Remote-SSH, host `hack`.

## Do not commit secrets

This repo is public. Never commit passwords, API keys, `.env` files or private keys. Only public keys
(`keys/*.pub`) belong here.

## Admin

See the Admin section of `AGENTS.md`. Server setup: `server/bootstrap.sh`. Members sync every minute
from `keys/*.pub`; delete a file to revoke access.
