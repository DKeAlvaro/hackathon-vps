# hackathon-vps: connect this computer to the team's shared hackathon VPS

This repo is the access kit for ONE shared Ubuntu 24.04 VPS, the "command center" of a 4-person,
72-hour hackathon team: alvaro (admin), bence, aranguren, hector. Each person has a personal invite
code; the connect script uses it to install this computer's SSH key on the server. The repo is public:
never put secrets (codes, tokens, private keys) in it. Connection details live in `hack.conf`.

## When the user says "connect me to the VPS" (or similar, in any language)

Run each command as its own short call (under 30 seconds). Agents have no terminal to answer prompts,
so always pass the name and code as arguments.

1. **Get the two facts.** Their name, one of `alvaro`, `bence`, `aranguren`, `hector`, and the personal
   code Alvaro sent them (format `xxxx-xxxx-xxxx`). If the user did not give both, ask for the missing one.
2. **Be inside the repo.** If the current directory has no `connect.sh` and `hack.conf`, run
   `git clone https://github.com/DKeAlvaro/hackathon-vps.git` and `cd hackathon-vps`.
   If it is already a clone, run `git pull --ff-only`.
3. **Run the connect script for their OS.**
   - Windows (PowerShell, the default on Windows):
     `powershell -ExecutionPolicy Bypass -File .\connect.ps1 -User <name> -Code <code>`
   - macOS, Linux, or Git Bash: `./connect.sh -u <name> -c <code>`

   It creates `~/.ssh/hack_ed25519` if missing, registers the public key at the server's `/join`
   endpoint (the code is the proof), writes a managed `Host hack` block into `~/.ssh/config`, and tests
   `ssh hack` (3 tries). Other flags: `--check` / `-Check` (only test ssh, exit 0 or 1),
   `--print` / `-Print` (show the config block and public key only).
   Errors are explained in plain text: wrong code (403), too many tries (429, wait 10 minutes),
   server unreachable, ssh blocked.
   If `hack.conf` still contains `__VPS_IP__` / `__WEB_URL__`, the admin has not published the address
   yet: tell the user to ask Alvaro, then `git pull`.
4. **Verify:** `ssh hack 'whoami; ls ~/hack'`. `whoami` must print the chosen name.
5. **Give the user the summary** printed by the script:
   - `ssh hack` opens a shell on the VPS.
   - Web links (login: user = their name, password = their code): landing page, Code (VS Code in the
     browser), Files (upload/download), Stats.
   - Send files with `./send.sh <paths>` (Windows: `.\send.ps1 <paths>`); they land in `~/hack/inbox/<name>/`.
   - The team project is `~/hack/project` on the VPS; VS Code / Cursor Remote-SSH, host `hack`.
   - `pair` on the VPS attaches to the shared tmux session.

Never edit `~/.ssh/config` by hand outside the `# >>> hackathon-vps >>>` block, never print or commit
private keys or codes, and never register a key for anyone but the user you are helping.

## Working on the VPS

- `~/hack` = `/srv/hack`, group `team`, setgid plus default ACLs, so everything anyone creates is
  readable and writable by the whole team. Layout:
  - `project/`: clone of the private repo `DKeAlvaro/hackathon`. `git push` works from the VPS through a
    deploy key (no login needed).
  - `wt/`: per-person worktrees. Do not edit one checkout from several agents; make your own:
    `git -C ~/hack/project worktree add ~/hack/wt/<user>-<feature> -b <user>/<feature>`
  - `inbox/<user>/`: files sent from laptops with `send.sh` / `send.ps1`.
  - `kit-agentes/`: agent kit (see below).
- Git identity is preset on the VPS: `user.name` = your display name, `user.email` = `<user>@hackathon.local`,
  `init.defaultBranch` = main. Change it with `git config --global` if you want.
- Run your own agent on the VPS: `ssh hack`, then `claude` or `codex` and log in with your own account.
  Claude Code and Codex are installed. Use `tmux` (or `pair`) so jobs survive disconnects. Detach with Ctrl-b d.
- `pair` is a shared tmux session everyone can join (`pair <name>` for more sessions).
- Web tools (log in with your name and personal code): Code `https://code.<base>` is VS Code in the browser,
  its file explorer updates live, so it is the real-time view of the files, plus editor, terminal, previews,
  drag-and-drop upload and right-click download. Files `https://files.<base>` is simple upload, download and
  share links. Stats `https://stats.<base>` is CPU, RAM, disk, processes and Docker. `<base>` is in `hack.conf`
  (`WEB_URL`).
- Ports open in the firewall: 22, 80, 443, 3000-3999, 5000-5999, 8000-8999 (tcp). Bind dev servers to
  `0.0.0.0` and open `http://<server-ip>:<port>`. Docker-published ports (`-p 8080:80`) bypass ufw and are
  reachable from the internet; use `-p 127.0.0.1:8080:80` to keep one private.
- RAM is 6 GB for everyone (plus everyone's agents): check `free -h` and `htop` before heavy builds or model runs.
- You have passwordless `sudo` and are in the `docker` group. Do not work as root.
- Installed: git, tmux, htop/btop, jq, ripgrep, fd, build-essential, Python 3 (pip, venv, pipx, uv),
  Node.js 22, Docker + compose, gh, Claude Code, Codex.
- Never commit secrets, codes or `.env` files; keep them in untracked files.

## Agent kit for the hackathon project

`/srv/hack/kit-agentes` is a clone of https://github.com/gruia-app/skills: six skills (servidor-agentes,
agentes-en-paralelo, revisar-codigo, diagnosticar-bugs, delegar-barato, relevo) plus an `AGENTS.md` template.
Set it up once in the project so every agent shares the same rules:
`mkdir -p .claude/skills && cp -r /srv/hack/kit-agentes/skills/* .claude/skills/ && cp /srv/hack/kit-agentes/plantillas/AGENTS.md .`
then fill in `AGENTS.md` in the first hour and add a `CLAUDE.md` containing `@AGENTS.md`. Work in parallel with
one git worktree per agent (see the agentes-en-paralelo skill).

## Troubleshooting

- `Permission denied (publickey)`: the key is not registered for that name. Re-run the connect script with the
  right `-u` / `-c` (the user in `~/.ssh/config` must match the name that owns the code).
- 403 "wrong user or code": retype the code exactly as sent (letters and digits, no 0/o/1/l/i). After 10 failed
  tries from one network the server blocks it for 10 minutes (429).
- Cannot reach `WEB_URL`: no internet, the server is down, or bootstrap is still running. The first HTTPS
  certificate can take about 30 s after setup. Ask Alvaro.
- `REMOTE HOST IDENTIFICATION HAS CHANGED`: the server was reinstalled. Run `ssh-keygen -R <HOST_IP from hack.conf>`
  and try again.
- Windows: `ssh` not found. In an administrator PowerShell:
  `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`, then open a new terminal.
- Timeout or "connection refused" on port 22: some corporate, school and public networks block it. Try a phone
  hotspot and tell the admin.
- `hack.conf` still says `__VPS_IP__`: the admin has not published the address yet; `git pull` later.
- `git push` on the VPS fails with "permission denied (publickey)" or the project folder is missing: the deploy
  key is not added to GitHub yet. Tell Alvaro (see Admin).

## Admin (alvaro, GitHub DKeAlvaro)

- Fresh server, as root: `curl -fsSL https://raw.githubusercontent.com/DKeAlvaro/hackathon-vps/main/server/bootstrap.sh | bash`
  (it clones itself to `/opt/hackathon-vps`). Afterwards: `bash /opt/hackathon-vps/server/bootstrap.sh`. It is idempotent.
  It installs `server/admin.pub` (Alvaro's key) for root and alvaro, creates the team users from `server/team.txt`,
  generates the codes, installs Caddy, code-server, File Browser, Glances and the join service, and prints a summary:
  URLs, the codes table, deploy key status, project clone status, service statuses.
- Then: put the server IP and `https://<ip-dashed>.sslip.io` in `hack.conf` (`HOST_IP`, `WEB_URL`), commit and push.
  Send each friend: "Tell your agent: clone https://github.com/DKeAlvaro/hackathon-vps and connect me to the VPS.
  I'm <name>, my code is <code>".
- Deploy key: bootstrap prints `/etc/hack/deploy_key.pub`. Add it with write access:
  `gh repo deploy-key add hack-vps.pub --repo DKeAlvaro/hackathon --allow-write --title hack-vps`, then re-run
  bootstrap to clone `/srv/hack/project` if the first clone failed.
- Codes live in `/etc/hack/codes` (`<user> <code>` per line, root only, never in the repo). They are also each
  person's password for the web tools (Caddy basic auth).
- Update path: push to `main`, then `ssh root@<ip> 'cd /opt/hackathon-vps && git pull -q && bash server/bootstrap.sh'`.
- Add a person: add `<username> <Display Name>` to `server/team.txt`, push, update on the server (new user, code,
  and Caddy login appear). Also add the name to the landing page text if you want.
- Revoke or rotate a code: edit its line in `/etc/hack/codes` (or delete the line and re-run bootstrap for a new
  one), re-run bootstrap so the Caddy hashes update, and remove that person's key lines from
  `/home/<user>/.ssh/authorized_keys` (the join endpoint appends, max 10 keys per user).
- Logs: `journalctl -u hack-join` (one line per join attempt, codes are never logged), `-u caddy`, `-u hack-code`,
  `-u hack-files`, `-u hack-stats`.
- Never merge changes to `server/` from anyone without reading them: bootstrap runs as root.
