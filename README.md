# hackathon-vps

For agents: read `AGENTS.md` and follow "When the user asks to set up / connect".
Do not improvise a setup from this README.

One shared Ubuntu 24.04 server for our 72-hour hackathon: the team's command center. Everyone gets their own
account (SSH key only), a shared folder, and a few web tools.

Server: Hostbrr, Frankfurt, 2 vCPU, 6 GB RAM, 80 GB NVMe, Ubuntu 24.04

## The 30-second version

Alvaro sends you a message like this:

> Set up github.com/DKeAlvaro/hackathon-vps for me, I'm bence, my code is k7m2-p9qx-4hzt

Paste it into Claude Code (or another coding agent). When it is done, open Claude Code in the `hackathon` folder
it created and type `/start`.

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
`hack` entry to `~/.ssh/config`, tests `ssh hack`, and clones the team project into a `hackathon` folder next to
this one (`--project-dir` / `-ProjectDir` to change it, `--no-project` / `-NoProject` to skip).

## Web file explorer

`WEB_URL` (in `hack.conf`) is a plain file explorer on the shared folder: upload and download files. Log in with
your name and your code. The first HTTPS certificate can take about 30 s after the server is set up.

## Sending files

```
./send.sh <paths>          # macOS / Linux / Git Bash
.\send.ps1 <paths>         # Windows PowerShell
```

Files land in `~/hack/inbox/<you>/` on the VPS. Get files back with `scp -r hack:~/hack/<path> .`

## How we work

Everyone codes on their own machine with their own Claude Code in the local `hackathon` clone: `/start`, `/ship`,
`/demo`. The workflow is in that repo's `AGENTS.md`. Nobody runs agents on the VPS (6 GB RAM shared by 4 people).

## On the server

- Shared folder `~/hack` (= `/srv/hack`): `project/` (live checkout of main), `project.git/` (central repo),
  `inbox/<you>/`, `kit-agentes/`.
- `pair` opens a tmux session everyone can join. VS Code / Cursor: Remote-SSH, host `hack`.
- Installed: git, tmux, htop/btop, jq, ripgrep, fd, build tools, Python 3 + pip/venv/pipx/uv, Node.js 22,
  Docker + compose, gh, File Browser, Caddy.
- Open ports: 22, 80, 443, 3000-3999, 5000-5999, 8000-8999. Docker-published ports bypass the firewall.
- Passwordless `sudo`, member of `docker`. RAM is shared (6 GB): be kind.

## Troubleshooting

- Web links don't load or show a certificate/name warning: your network's DNS blocks sslip.io (seen on DNA in Finland). Set your DNS to 1.1.1.1 / 8.8.8.8 or use a phone hotspot. ssh, git and send don't depend on it; the connect script also works around it.

## Do not commit secrets

This repo is public. Never commit codes, passwords, API keys, `.env` files or private keys.

## Admin

See the Admin section of `AGENTS.md`. Server setup: `server/bootstrap.sh`; the team is `server/team.txt`.
