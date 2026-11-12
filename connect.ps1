# Connect this Windows computer to the shared hackathon VPS (PowerShell 5.1+, built-in OpenSSH client).
# Usage: powershell -ExecutionPolicy Bypass -File .\connect.ps1 [-User NAME] [-NoPr] [-Wait MINUTES] [-Check] [-Print]
[CmdletBinding()]
param(
    [Alias('u')][string]$User = $env:HACK_USER,
    [Alias('no-pr')][switch]$NoPr,
    [int]$Wait = 0,
    [switch]$Check,
    [switch]$Print
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$NameRe = '^[a-z][a-z0-9-]{0,30}$'
$BeginMark = '# >>> hackathon-vps >>>'
$EndMark = '# <<< hackathon-vps <<<'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Step($n, $text) { Write-Host ""; Write-Host "[$n] $text" }

# Quote one argument for a Windows command line.
function Q([string]$s) { '"' + ($s -replace '"', '\"') + '"' }

# Run a native program with an explicit argument string (avoids PowerShell 5.1 quoting bugs,
# e.g. empty arguments being dropped). Returns @{ ExitCode; Out }.
function Invoke-Native([string]$File, [string]$ArgLine, [switch]$Capture) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = [bool]$Capture
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = ''
    if ($Capture) { $out = $p.StandardOutput.ReadToEnd() }
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Out = $out.Trim() }
}

function Has-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# ---- 1. read hack.conf ----
Step 1 'Reading hack.conf'
$confPath = Join-Path $Root 'hack.conf'
if (-not (Test-Path $confPath)) { Write-Error "hack.conf not found in $Root"; exit 1 }
$conf = @{}
foreach ($line in [System.IO.File]::ReadAllLines($confPath)) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') { $conf[$Matches[1]] = $Matches[2].Trim() }
}
foreach ($k in 'HOST_ALIAS', 'HOST_IP', 'SSH_PORT', 'REPO') {
    if (-not $conf[$k]) { Write-Error "hack.conf is incomplete (missing $k)"; exit 1 }
}
$HostAlias = $conf['HOST_ALIAS']; $HostIp = $conf['HOST_IP']; $SshPort = $conf['SSH_PORT']; $Repo = $conf['REPO']
if ($HostIp -eq '__VPS_IP__') {
    Write-Host 'hack.conf still has the placeholder HOST_IP=__VPS_IP__.'
    Write-Host 'The repo owner has not filled in the server IP yet. Ask the admin (DKeAlvaro) and pull again.'
    exit 1
}
Write-Host "host alias $HostAlias -> ${HostIp}:$SshPort, repo $Repo"

if (-not (Has-Command 'ssh')) {
    Write-Host 'The OpenSSH client is missing. In an ADMIN PowerShell run:'
    Write-Host '  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'
    exit 1
}

function Test-Ssh {
    $r = Invoke-Native 'ssh' "-o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=QUIET $HostAlias true" -Capture
    return ($r.ExitCode -eq 0)
}

if ($Check) {
    if (Test-Ssh) { Write-Host "OK: ssh $HostAlias works"; exit 0 }
    Write-Host "NOT YET: ssh $HostAlias does not work"
    exit 1
}

# ---- 2. username ----
Step 2 'Choosing the Linux username'
if (-not $User -and (Has-Command 'gh')) {
    $r = Invoke-Native 'gh' 'api user -q .login' -Capture
    if ($r.ExitCode -eq 0) {
        $guess = $r.Out.ToLower()
        if ($guess -match $NameRe) { $User = $guess; Write-Host "derived from GitHub login: $User" }
    }
}
if (-not $User) {
    if (-not [Console]::IsInputRedirected) {
        $User = Read-Host 'Username on the VPS (lowercase letters, digits, hyphens)'
    } else {
        Write-Host 'No username known and no terminal to ask. Re-run with: -User <name>'
        exit 1
    }
}
$User = $User.Trim().ToLower()
if ($User -notmatch $NameRe) { Write-Host "Invalid username '$User': must match $NameRe"; exit 1 }
Write-Host "username: $User"

# ---- 3. key ----
Step 3 'SSH key'
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = $HOME }
$SshDir = Join-Path $UserHome '.ssh'
$Key = Join-Path $SshDir 'hack_ed25519'
if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir | Out-Null }
if (Test-Path $Key) {
    Write-Host "using existing key $Key"
} else {
    Write-Host "creating $Key"
    # Empty passphrase passed as a literal "" inside an explicit argument string.
    $r = Invoke-Native 'ssh-keygen' ('-q -t ed25519 -N "" -C ' + (Q "$User@hackathon") + ' -f ' + (Q $Key))
    if ($r.ExitCode -ne 0 -or -not (Test-Path $Key)) { Write-Host 'ssh-keygen failed'; exit 1 }
}
if (-not (Test-Path "$Key.pub")) {
    $r = Invoke-Native 'ssh-keygen' ('-y -f ' + (Q $Key)) -Capture
    [System.IO.File]::WriteAllText("$Key.pub", $r.Out + "`n", $Utf8NoBom)
}
$PubKey = ([System.IO.File]::ReadAllLines("$Key.pub") | Select-Object -First 1).Trim()
$KeyBlob = ($PubKey -split '\s+')[1]

$ConfigBlock = @(
    $BeginMark,
    "Host $HostAlias",
    "    HostName $HostIp",
    "    Port $SshPort",
    "    User $User",
    '    IdentityFile ~/.ssh/hack_ed25519',
    '    IdentitiesOnly yes',
    '    ServerAliveInterval 30',
    '    ServerAliveCountMax 6',
    '    StrictHostKeyChecking accept-new',
    $EndMark
)

if ($Print) {
    Write-Host ''
    Write-Host "--- ssh config block ($SshDir\config) ---"
    $ConfigBlock | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "--- public key (keys/$User.pub) ---"
    Write-Host $PubKey
    exit 0
}

# ---- 4. ssh config ----
Step 4 "Updating $SshDir\config"
$Cfg = Join-Path $SshDir 'config'
$old = ''
if (Test-Path $Cfg) { $old = [System.IO.File]::ReadAllText($Cfg) }
$nl = "`n"
if ($old -match "`r`n") { $nl = "`r`n" }
$pattern = '(?s)' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark) + '(\r?\n)?'
$rest = ([regex]::Replace($old, $pattern, '')).TrimEnd()
$new = ''
if ($rest.Length -gt 0) { $new = $rest + $nl + $nl }
$new += ($ConfigBlock -join $nl) + $nl
if ($new -ceq $old) {
    Write-Host 'config block already up to date'
} else {
    [System.IO.File]::WriteAllText($Cfg, $new, $Utf8NoBom)
    Write-Host 'config block written'
}

# ---- 5. test ----
function Show-NextSteps {
    Write-Host ''
    Write-Host 'You are connected. Next:'
    Write-Host "  ssh $HostAlias            open a shell on the VPS"
    Write-Host '  pair                       (on the VPS) shared tmux session with the team'
    Write-Host '  ~/hack                     shared projects folder (/srv/hack)'
    Write-Host "  VS Code / Cursor: Remote-SSH, connect to host `"$HostAlias`""
}

Step 5 "Testing ssh $HostAlias"
if (Test-Ssh) { Write-Host "ssh $HostAlias works"; Show-NextSteps; exit 0 }
Write-Host 'not connected yet (account probably does not exist yet)'

# ---- 6. membership ----
Step 6 "Requesting access (keys/$User.pub)"
$KeysDir = Join-Path $Root 'keys'
if (-not (Test-Path $KeysDir)) { New-Item -ItemType Directory -Path $KeysDir | Out-Null }
$KeyFile = Join-Path $KeysDir "$User.pub"
$have = $false
if (Test-Path $KeyFile) { $have = ([System.IO.File]::ReadAllText($KeyFile)).Contains($KeyBlob) }
if ($have) {
    Write-Host "local keys/$User.pub already has your key"
} else {
    $prev = ''
    if (Test-Path $KeyFile) { $prev = [System.IO.File]::ReadAllText($KeyFile) }
    if ($prev.Length -gt 0 -and -not $prev.EndsWith("`n")) { $prev += "`n" }
    [System.IO.File]::WriteAllText($KeyFile, $prev + $PubKey + "`n", $Utf8NoBom)
    Write-Host "wrote your key to keys/$User.pub"
}

function Show-Manual {
    Write-Host ''
    Write-Host 'Send this public key to the admin (DKeAlvaro), or open a pull request on'
    Write-Host "https://github.com/$Repo adding it as keys/$User.pub :"
    Write-Host ''
    Write-Host $PubKey
    Write-Host ''
}

$GitGh = '-c credential.helper= -c "credential.helper=!gh auth git-credential"'

function Submit-WithGh {
    $login = (Invoke-Native 'gh' 'api user -q .login' -Capture).Out
    $canPush = (Invoke-Native 'gh' ('api ' + (Q "repos/$Repo") + ' -q .permissions.push') -Capture).Out
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('hackvps-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $clone = Join-Path $tmp 'repo'
        $r = Invoke-Native 'git' ('clone -q --depth 1 ' + (Q "https://github.com/$Repo.git") + ' ' + (Q $clone))
        if ($r.ExitCode -ne 0) { Write-Host 'git clone failed'; return $false }
        $ident = ''
        if ((Invoke-Native 'git' ('-C ' + (Q $clone) + ' config user.email') -Capture).Out -eq '') {
            $ident = '-c ' + (Q "user.name=$login") + ' -c ' + (Q "user.email=$login@users.noreply.github.com") + ' '
        }
        $g = '-C ' + (Q $clone) + ' '
        New-Item -ItemType Directory -Force -Path (Join-Path $clone 'keys') | Out-Null
        $target = Join-Path $clone "keys\$User.pub"
        $prev = ''
        if (Test-Path $target) { $prev = [System.IO.File]::ReadAllText($target) }
        if ($prev.Contains($KeyBlob)) {
            Write-Host "your key is already in $Repo main; the VPS picks it up within a minute"
            return $true
        }
        if ($prev.Length -gt 0) {
            Write-Host "WARNING: keys/$User.pub already exists upstream with other keys; adding yours as an extra line"
            if (-not $prev.EndsWith("`n")) { $prev += "`n" }
        }
        [System.IO.File]::WriteAllText($target, $prev + $PubKey + "`n", $Utf8NoBom)
        $rel = "keys/$User.pub"

        if ($canPush -eq 'true') {
            Write-Host 'you have push access: committing to main'
            Invoke-Native 'git' ($g + 'add ' + (Q $rel)) | Out-Null
            Invoke-Native 'git' ($g + $ident + 'commit -q -m ' + (Q "Add $User")) | Out-Null
            $r = Invoke-Native 'git' ($g + $GitGh + ' push -q ' + (Q "https://github.com/$Repo.git") + ' HEAD:main')
            if ($r.ExitCode -ne 0) { return $false }
            Write-Host 'pushed to main'
            return $true
        }

        $branch = "add-$User"
        $existing = (Invoke-Native 'gh' ('pr list --repo ' + (Q $Repo) + ' --head ' + (Q "${login}:$branch") + ' --state open --json number -q length') -Capture).Out
        Invoke-Native 'git' ($g + 'checkout -q -b ' + (Q $branch)) | Out-Null
        Invoke-Native 'git' ($g + 'add ' + (Q $rel)) | Out-Null
        Invoke-Native 'git' ($g + $ident + 'commit -q -m ' + (Q "Add $User")) | Out-Null
        Invoke-Native 'gh' ('repo fork ' + (Q $Repo) + ' --clone=false') -Capture | Out-Null
        $repoName = $Repo.Split('/')[1]
        $forkUrl = "https://github.com/$login/$repoName.git"
        $pushed = $false
        for ($i = 1; $i -le 5; $i++) {
            $r = Invoke-Native 'git' ($g + $GitGh + ' push -q --force ' + (Q $forkUrl) + ' ' + (Q $branch))
            if ($r.ExitCode -eq 0) { $pushed = $true; break }
            Write-Host 'fork not ready, retrying...'
            Start-Sleep -Seconds 4
        }
        if (-not $pushed) { Write-Host "could not push to your fork $forkUrl"; return $false }
        if ($existing -and $existing -ne '0') {
            Write-Host "a pull request from ${login}:$branch is already open; updated it"
        } else {
            $r = Invoke-Native 'gh' ('pr create --repo ' + (Q $Repo) + ' --base main --head ' + (Q "${login}:$branch") +
                ' --title ' + (Q "Add $User") + ' --body ' + (Q "Adds keys/$User.pub so $User can access the hackathon VPS."))
            if ($r.ExitCode -ne 0) { return $false }
        }
        Write-Host 'Ask the admin (DKeAlvaro) to merge the pull request; the account appears within about a minute.'
        return $true
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

if ($NoPr) {
    Write-Host '-NoPr given: not pushing anything'
    Show-Manual
} elseif ((Has-Command 'gh') -and ((Invoke-Native 'gh' 'auth status' -Capture).ExitCode -eq 0)) {
    if (-not (Submit-WithGh)) {
        Write-Host 'Automatic submission failed.'
        Show-Manual
    }
} else {
    Write-Host 'gh is not installed or not logged in'
    Show-Manual
}

# ---- 7. wait ----
Step 7 'Waiting for access'
if ($Wait -gt 0) {
    $deadline = (Get-Date).AddMinutes($Wait)
    while ((Get-Date) -lt $deadline) {
        if (Test-Ssh) { Write-Host "ssh $HostAlias works"; Show-NextSteps; exit 0 }
        Write-Host 'not yet, retrying in 15 s...'
        Start-Sleep -Seconds 15
    }
    Write-Host "Timed out after $Wait minute(s). Re-run connect.ps1 -Check later."
    exit 1
}
Write-Host 'Not waiting. Once the admin has merged, check with:  .\connect.ps1 -Check'
Write-Host '(or keep polling with .\connect.ps1 -Wait 10)'
exit 1
