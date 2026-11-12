# hackathon-vps

One shared Ubuntu 24.04 server for our 72-hour hackathon: the team's command center. Everyone gets their own
account (SSH key only), a shared folder, and a few web tools.

Server: __VPS_SPECS__

## The 30-second version

Alvaro sends you a message like this:

> Tell your agent: clone https://github.com/DKeAlvaro/hackathon-vps and connect me to the VPS.
> I'm bence, my code is k7m2-p9qx-4hzt

Paste it into your coding agent (Claude Code, Codex, Cursor, ...). The agent reads `AGENTS.md` and does
everything. When it is done, `ssh hack` works and you get the web links.

The team: `alvaro`, `bence`, `aranguren`, `hector`. Your code is personal: do not share it.

## Manual setup (no agent)

Windows PowerShell:

```
git clone https://github.com/DKeAlvaro/hackathon-vps.git; cd hackathon-vps
powershell -ExecutionPolicy Bypass -File .\connect.ps1 -User yourname -Code xxxx-xxxx-xxxx
```

macOS / Linux / Git Bash:

```
git clone https://github.com/DKeAlvaro/hackathon-vps.git && cd hackathon-vps
./connect.sh -u yourname -c xxxx-xxxx-xxxx
```

The script creates `~/.ssh/hack_ed25519`, registers the public key with the server using your code, adds a
`hack` entry to `~/.ssh/config`, and tests `ssh hack`.

## Web tools

Log in with your name and your code. The links are printed by the connect script and listed on the landing
page (`WEB_URL` in `hack.conf`). The first HTTPS certificate can take about 30 s after the server is set up.

- Code: VS Code in the browser on `/srv/hack`. The file explorer updates live (the real-time view of
  everything), plus editor, terminal, previews, drag-and-drop upload and right-click download.
- Files: File Browser, drag-and-drop upload, download, share links.
- Stats: Glances, CPU, RAM, disk, processes, Docker containers.

## Sending files

```
./send.sh <paths>          # macOS / Linux / Git Bash
.\send.ps1 <paths>         # Windows PowerShell
```

Files land in `~/hack/inbox/<you>/` on the VPS. Get files back with `scp -r hack:~/hack/<path> .`

## On the server

- Shared folder `~/hack` (= `/srv/hack`): `project/` (clone of the private repo DKeAlvaro/hackathon, push works
  from the VPS), `wt/` (worktrees per person), `inbox/<you>/`, `kit-agentes/`.
- `pair` opens a tmux session everyone can join. VS Code / Cursor: Remote-SSH, host `hack`.
- Run your own agent there: `ssh hack`, then `claude` or `codex`.
- Installed: git, tmux, htop/btop, jq, ripgrep, fd, build tools, Python 3 + pip/venv/pipx/uv, Node.js 22,
  Docker + compose, gh, Claude Code, Codex, code-server, File Browser, Glances, Caddy.
- Open ports: 22, 80, 443, 3000-3999, 5000-5999, 8000-8999. Docker-published ports bypass the firewall.
- Passwordless `sudo`, member of `docker`. RAM is shared (6 GB): be kind.

## Do not commit secrets

This repo is public. Never commit codes, passwords, API keys, `.env` files or private keys.

## Admin

See the Admin section of `AGENTS.md`. Server setup: `server/bootstrap.sh`; the team is `server/team.txt`.
