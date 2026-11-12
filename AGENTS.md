# hackathon-vps: connect this computer to the team's shared hackathon VPS

This repo gives a group of friends access to ONE shared Ubuntu 24.04 VPS for a 72-hour hackathon.
Members are the files `keys/<username>.pub`; the server syncs them every minute. The repo is public:
never put secrets in it. Connection details live in `hack.conf`.

## When the user says "connect me to the VPS" (or similar, in any language)

Do this, in order. Run each command as its own short call (under 30 seconds).

1. **Be inside the repo.** If the current directory is not a clone of this repo (no `connect.sh` and
   `hack.conf`), run `git clone https://github.com/DKeAlvaro/hackathon-vps.git` and `cd hackathon-vps`.
   If it is a clone, run `git pull --ff-only` first.
2. **Pick the Linux username.** It must be lowercase and match `^[a-z][a-z0-9-]{0,30}$`
   (letters, digits, hyphens; starts with a letter). Ask the user which name they want unless it is obvious
   (their GitHub login lowercased is a good default). Always pass it explicitly with `-u` / `-User`,
   because agents have no terminal to answer prompts.
3. **Run the connect script.**
   - macOS, Linux, or Git Bash on Windows:
     `./connect.sh -u <username>`
   - Windows PowerShell (use this on Windows unless the user is clearly in Git Bash):
     `powershell -ExecutionPolicy Bypass -File .\connect.ps1 -User <username>`

   It creates `~/.ssh/hack_ed25519` (if missing), writes a managed `Host hack` block into `~/.ssh/config`,
   tests the connection, and if the account does not exist yet it requests access: with `gh` logged in it
   commits the key to `keys/<username>.pub` and pushes to `main` (if the user has push access) or opens a
   pull request; without `gh` it prints the public key. Flags: `--no-pr` / `-NoPr` (do not push or open a PR),
   `--wait N` / `-Wait N` (poll up to N minutes), `--check` / `-Check` (only test, exit 0 or 1),
   `--print` / `-Print` (show config block and public key only).
   The script exits 1 when access is not working yet; that is expected the first time.
4. **If a pull request was opened** (or the key was only printed): tell the user to ask the admin
   @DKeAlvaro to merge it (or to send the printed public key to the admin). Merging takes effect within
   about a minute. Do not try to merge it yourself.
5. **Poll with `--check`, in short separate commands** (each under 30 seconds, never one long blocking
   call): `./connect.sh --check` or `powershell -ExecutionPolicy Bypass -File .\connect.ps1 -Check`.
   Exit 0 means it works. Wait 20-30 seconds between tries (use a short sleep as its own command) and
   stop after about 10 minutes; if it still fails, see Troubleshooting and tell the user.
6. **Verify:** `ssh hack 'whoami; ls ~/hack'`. `whoami` must print the chosen username.
7. **Tell the user the one-liners:**
   - `ssh hack` opens a shell on the VPS.
   - `pair` (on the VPS) attaches to the shared tmux session everyone can join (`pair <name>` for others).
   - VS Code / Cursor: Remote-SSH extension, connect to host `hack`.
   - Shared projects live in `~/hack` (which is `/srv/hack`); everyone on the team can read and write there.
8. Optionally set the git identity on the VPS (see below).

Never edit `~/.ssh/config` by hand outside the `# >>> hackathon-vps >>>` block, never print or
commit private keys, and do not commit `keys/<username>.pub` for anyone but the user you are helping.

## Working on the VPS

- Shared folder: `~/hack` = `/srv/hack`, group `team`, setgid plus default ACLs, so everything anyone
  creates is readable and writable by the whole team. Put each project in its own folder there.
- Use `pair` for a shared tmux session (the first person to run it owns the tmux server). Use plain
  `tmux` for private long-running jobs: they survive disconnects. Detach with Ctrl-b d.
- Git identity is per user and not preconfigured. Run on the VPS:
  `git config --global user.name "Your Name"` and `git config --global user.email "you@example.com"`.
- Do not work as root. Your user is in the `sudo` group with passwordless sudo and in `docker`; use
  `sudo` only when needed.
- Ports open in the firewall (ufw): 22, 80, 443, 3000-3999, 5000-5999, 8000-8999 (tcp). Bind dev servers
  to `0.0.0.0` and open `http://<server-ip>:<port>`. Docker-published ports (`-p 8080:80`) bypass ufw and
  are reachable from the internet; use `-p 127.0.0.1:8080:80` to keep one private.
- RAM and CPU are shared by everyone: check `free -h` and `htop` before heavy builds or model runs.
- Installed: git, tmux, htop/btop, jq, ripgrep, fd, build-essential, Python 3 (pip, venv, pipx, uv),
  Node.js 22, Docker + compose, gh, Claude Code (`claude`), Codex (`codex`). Never commit secrets or
  `.env` files to the public repo; put them in untracked files.

## Troubleshooting

- `Permission denied (publickey)`: the PR is not merged yet (wait a minute after merging), or the
  username in `~/.ssh/config` does not match the name of your `keys/<username>.pub`, or the key differs
  (`ssh-keygen -y -f ~/.ssh/hack_ed25519` must match the line in the repo). Re-run the connect script.
- `REMOTE HOST IDENTIFICATION HAS CHANGED`: the server was reinstalled. Run
  `ssh-keygen -R <HOST_IP from hack.conf>` and try again.
- Windows: `ssh` not found. In an administrator PowerShell:
  `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`, then open a new terminal.
- Timeout or "connection refused": some corporate, school and public networks block port 22. Try a phone
  hotspot, and tell the admin.
- `hack.conf` still says `__VPS_IP__`: the admin has not published the IP yet; `git pull` later.
- `gh` is not logged in: run `gh auth login`, or use `--no-pr` and send the public key to the admin.

## Admin (@DKeAlvaro)

- Merge PRs that add `keys/<username>.pub` (check that the file name is the intended username and that
  it contains only public key lines). The VPS pulls `main` every minute and creates the account.
- A user with push access can push to `main` directly (the connect script does that automatically).
- Sync log on the server: `/var/log/hack-sync.log`. Cron file: `/etc/cron.d/hack-sync`. The clone is in
  `/opt/hackathon-vps`.
- Fresh server: as root, `curl -fsSL https://raw.githubusercontent.com/DKeAlvaro/hackathon-vps/main/server/bootstrap.sh | bash`.
  It is idempotent. Put the root key in `/root/.ssh/authorized_keys` first (SSH hardening is skipped when no key exists).
- Remove a member: delete their `keys/<username>.pub` and merge. Their `authorized_keys` is emptied within a minute;
  the user and home directory stay.
- Names that exist as system accounts (UID below 1000) and `root` are refused by the sync.
