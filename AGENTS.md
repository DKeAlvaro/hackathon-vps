# hackathon-vps: connect this computer to the team's shared hackathon VPS

This repo is the access kit for ONE shared Ubuntu 24.04 VPS, the "command center" of a 4-person,
72-hour hackathon team: alvaro (admin), bence, aranguren, hector. Each person has a personal invite
code; the connect script uses it to install this computer's SSH key on the server. The repo is public:
never put secrets (codes, tokens, private keys) in it. Connection details live in `hack.conf`.

## When the user asks to set up / connect

Triggers: anything like "set up github.com/DKeAlvaro/hackathon-vps for me, I'm <name>, code <code>" or
"connect me to the VPS" (any language). Run each command as its own short call (under 30 seconds). Agents have
no terminal to answer prompts, so always pass the name and code as arguments.

1. **Get the two facts.** Name: one of `alvaro`, `bence`, `aranguren`, `hector`. Code: the personal code Alvaro
   sent (`xxxx-xxxx-xxxx`). If either is missing, ask for it.
2. **Be inside the repo.** If the current directory has no `connect.sh` and `hack.conf`, run
   `git clone https://github.com/DKeAlvaro/hackathon-vps.git` and `cd hackathon-vps`. If it is already a clone,
   `git pull --ff-only`.
3. **Run `./connect.sh -u <name> -c <code>`.** Claude Code on Windows runs Git Bash, so this works on every OS.
   Use `powershell -ExecutionPolicy Bypass -File .\connect.ps1 -User <name> -Code <code>` only as a fallback
   for plain PowerShell. The script creates `~/.ssh/hack_ed25519`, registers the key with the server (the code is
   the proof), writes a managed `Host hack` block in `~/.ssh/config`, tests `ssh hack`, clones the team project
   to the sibling folder `hackathon` (`git clone hack:/srv/hack/project.git`) and sets
   `git config hackathon.user <name>` there. Flags: `--check` (only test ssh), `--print`, `--project-dir <path>`,
   `--no-project`. Errors are explained in plain text (wrong code 403, too many tries 429: wait 10 minutes,
   server unreachable, ssh blocked). If `hack.conf` has `__VPS_IP__`, the admin has not published the address:
   tell the user to ask Alvaro, then `git pull`.
4. **Verify:** `ssh hack whoami` must print the chosen name.
5. **Tell the user exactly:** "Done. Open Claude Code in <projectdir> and type /start." (`<projectdir>` is the
   absolute path of the `hackathon` folder the script printed.) Add `ssh hack` and the web file explorer URL
   (`WEB_URL`; login = their name + code).

Never edit `~/.ssh/config` by hand outside the `# >>> hackathon-vps >>>` block, never print or commit private
keys or codes, and never register a key for anyone but the user you are helping.

## How we work

The workflow (claim tasks, worktrees, shipping, shared demo) lives in the project repo's `AGENTS.md`
(`hackathon/AGENTS.md`, slash commands `/start`, `/ship`, `/demo`). Read that, not this file.
The VPS is the hub (central git `hack:/srv/hack/project.git`, shared demo, `~/hack/`, `~/hack/inbox/<user>/`,
web file explorer); nobody runs coding agents on it (6 GB RAM shared). Never push to GitHub `DKeAlvaro/hackathon`.
`pair` on the VPS is a shared tmux session. Open ports: 22, 80, 443, 3000-3999, 5000-5999, 8000-8999.

## Agent kit for the hackathon project

`/srv/hack/kit-agentes` is a clone of https://github.com/gruia-app/skills: six skills (servidor-agentes,
agentes-en-paralelo, revisar-codigo, diagnosticar-bugs, delegar-barato, relevo) plus an `AGENTS.md` template.
Set it up once in the project so every agent shares the same rules:
`mkdir -p .claude/skills && cp -r /srv/hack/kit-agentes/skills/* .claude/skills/ && cp /srv/hack/kit-agentes/plantillas/AGENTS.md .`
then fill in `AGENTS.md` in the first hour and add a `CLAUDE.md` containing `@AGENTS.md`. Copy it to your own machine (`scp -r hack:/srv/hack/kit-agentes .`) or clone it from GitHub, commit the result
to the project, and work in parallel with one local git worktree per agent (see the agentes-en-paralelo skill).
Skills that assume agents run on the server do not apply: agents run locally.

## Troubleshooting

- `Permission denied (publickey)`: the key is not registered for that name. Re-run the connect script with the
  right `-u` / `-c` (the user in `~/.ssh/config` must match the name that owns the code).
- 403 "wrong user or code": retype the code exactly as sent (letters and digits, no 0/o/1/l/i). After 10 failed
  tries from one network the server blocks it for 10 minutes (429).
- Cannot reach `WEB_URL`: no internet, the server is down, or bootstrap is still running. The first HTTPS
  certificate can take about 30 s after setup. Ask Alvaro.
- Web links don't load or show a certificate/name warning: your network's DNS blocks sslip.io (seen on DNA in Finland). Set your DNS to 1.1.1.1 / 8.8.8.8 or use a phone hotspot. ssh, git and send don't depend on it; the connect script also works around it.
- `REMOTE HOST IDENTIFICATION HAS CHANGED`: the server was reinstalled. Run `ssh-keygen -R <HOST_IP from hack.conf>`
  and try again.
- Windows: `ssh` not found. In an administrator PowerShell:
  `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`, then open a new terminal.
- Timeout or "connection refused" on port 22: some corporate, school and public networks block it. Try a phone
  hotspot and tell the admin.
- `hack.conf` still says `__VPS_IP__`: the admin has not published the address yet; `git pull` later.
- `git clone` / `git push` to `hack:` fails: check `ssh hack true` first. If ssh works but `/srv/hack/project.git`
  is missing, the server could not create it from GitHub yet (deploy key not added). Tell Alvaro (see Admin).
- `git push` to `main` rejected with "main cannot be force-pushed": run `git pull --rebase` and push again.
- Push went through but GitHub is behind: the mirror runs in the background; Alvaro checks `/srv/hack/.mirror.log`.
- Your edits in `~/hack/project` vanished: it is reset to `main` on every push. Work in your local clone.

## Admin (alvaro, GitHub DKeAlvaro)

- Fresh server, as root: `curl -fsSL https://raw.githubusercontent.com/DKeAlvaro/hackathon-vps/main/server/bootstrap.sh | bash`
  (it clones itself to `/opt/hackathon-vps`). Afterwards: `bash /opt/hackathon-vps/server/bootstrap.sh`. It is idempotent.
  It installs `server/admin.pub` (Alvaro's key) for root and alvaro, creates the team users from `server/team.txt`,
  generates the codes, installs Caddy, File Browser and the join service, and prints a summary:
  URLs, the codes table, deploy key status, central repo and live checkout status, service statuses.
- Then: put the server IP and `https://<ip-dashed>.sslip.io` in `hack.conf` (`HOST_IP`, `WEB_URL`), commit and push.
  Send each friend: "Tell your agent: clone https://github.com/DKeAlvaro/hackathon-vps and connect me to the VPS.
  I'm <name>, my code is <code>".
- Git layout: the central repo is the bare `/srv/hack/project.git` (shared group repo, remote `github`), the live
  checkout is `/srv/hack/project` (clone of it, on `main`). Hooks come from `server/git/` and are re-installed on
  every bootstrap: `pre-receive` rejects force-push and deletion of `main`; `post-receive` resets the live checkout
  to `main` and mirrors all branches and tags to GitHub in the background (`push --prune`, so branches deleted
  here disappear there). GitHub is only a mirror/backup, so friends need no GitHub account.
- Mirror log: `/srv/hack/.mirror.log` (one entry per failed mirror push; empty is good). Test it by hand:
  `git --git-dir=/srv/hack/project.git push --prune github 'refs/heads/*:refs/heads/*'`.
- Deploy key: bootstrap prints `/etc/hack/deploy_key.pub`. Add it with write access:
  `gh repo deploy-key add hack-vps.pub --repo DKeAlvaro/hackathon --allow-write --title hack-vps`, then re-run
  bootstrap to create `/srv/hack/project.git` and `/srv/hack/project` if the first clone failed. The key is used
  for the mirror (`core.sshCommand` in the bare repo) and is readable by group `team`, so hooks work for every pusher.
- If GitHub ever gets ahead (someone pushed there directly), the mirror push of `main` fails (see the log). Fix it
  on the server: `git --git-dir=/srv/hack/project.git fetch github main:refs/remotes/github/main`, inspect, merge
  it into `main` on a laptop (fetch from the server's bare repo after that fetch, or add GitHub as a second remote)
  and push `main` to the VPS; the next mirror push then succeeds.
- Codes live in `/etc/hack/codes` (`<user> <code>` per line, root only, never in the repo). They are also each
  person's password for the web file explorer (Caddy basic auth).
- Update path: push to `main`, then `ssh root@<ip> 'cd /opt/hackathon-vps && git pull -q && bash server/bootstrap.sh'`.
- Add a person: add `<username> <Display Name>` to `server/team.txt`, push, update on the server (new user, code,
  and Caddy login appear).
- Revoke or rotate a code: edit its line in `/etc/hack/codes` (or delete the line and re-run bootstrap for a new
  one), re-run bootstrap so the Caddy hashes update, and remove that person's key lines from
  `/home/<user>/.ssh/authorized_keys` (the join endpoint appends, max 10 keys per user).
- Logs: `journalctl -u hack-join` (one line per join attempt, codes are never logged), `-u caddy`, `-u hack-files`.
- Never merge changes to `server/` from anyone without reading them: bootstrap runs as root.
