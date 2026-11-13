# Connect this Windows computer to the shared hackathon VPS (PowerShell 5.1+, built-in OpenSSH client).
# Usage: powershell -ExecutionPolicy Bypass -File .\connect.ps1 -User NAME -Code CODE [-Check] [-Print] [-ProjectDir PATH] [-NoProject]
[CmdletBinding()]
param(
    [Alias('u')][string]$User = $env:HACK_USER,
    [Alias('c')][string]$Code = $env:HACK_CODE,
    [switch]$Check,
    [switch]$Print,
    [string]$ProjectDir = '',
    [switch]$NoProject
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$OrigDir = (Get-Location).Path
$CodeRe = '^[a-hj-km-np-z2-9]{4}-[a-hj-km-np-z2-9]{4}-[a-hj-km-np-z2-9]{4}$'
$BeginMark = '# >>> hackathon-vps >>>'
$EndMark = '# <<< hackathon-vps <<<'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

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
if (-not (Test-Path $confPath)) { Write-Host "hack.conf not found in $Root"; exit 1 }
$conf = @{}
foreach ($line in [System.IO.File]::ReadAllLines($confPath)) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') { $conf[$Matches[1]] = $Matches[2].Trim() }
}
foreach ($k in 'HOST_ALIAS', 'HOST_IP', 'SSH_PORT', 'WEB_URL') {
    if (-not $conf[$k]) { Write-Host "hack.conf is incomplete (missing $k)"; exit 1 }
}
$HostAlias = $conf['HOST_ALIAS']; $HostIp = $conf['HOST_IP']; $SshPort = $conf['SSH_PORT']
$WebUrl = $conf['WEB_URL'].TrimEnd('/'); $ProjectRepo = $conf['PROJECT_REPO']
if ($HostIp -eq '__VPS_IP__' -or $WebUrl -eq '__WEB_URL__') {
    Write-Host 'hack.conf still has placeholders (__VPS_IP__ / __WEB_URL__).'
    Write-Host 'The admin has not published the server address yet. Ask Alvaro, then run: git pull'
    exit 1
}
Write-Host "host alias $HostAlias -> ${HostIp}:$SshPort, web $WebUrl"

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
    Write-Host "NOT OK: ssh $HostAlias does not work"
    exit 1
}

# ---- 2. user and code ----
Step 2 'Checking your name and code'
$teamPath = Join-Path $Root 'server\team.txt'
if (-not (Test-Path $teamPath)) { Write-Host 'server\team.txt not found'; exit 1 }
$Team = @()
foreach ($line in [System.IO.File]::ReadAllLines($teamPath)) {
    $t = $line.Trim()
    if ($t -and -not $t.StartsWith('#')) { $Team += ($t -split '\s+')[0] }
}
$TeamList = $Team -join ' '
$User = ('' + $User).Trim().ToLower()
$Code = ('' + $Code).Trim().ToLower()
$interactive = -not [Console]::IsInputRedirected
if (-not $User) {
    if ($interactive) { $User = (Read-Host "Your name ($TeamList)").Trim().ToLower() }
    else { Write-Host "Missing -User NAME. Choose one of: $TeamList"; exit 1 }
}
if ($Team -notcontains $User) { Write-Host "Unknown user '$User'. The team is: $TeamList"; exit 1 }
if (-not $Code) {
    if ($interactive) { $Code = (Read-Host 'Your personal code (xxxx-xxxx-xxxx)').Trim().ToLower() }
    else { Write-Host 'Missing -Code CODE (the personal code Alvaro sent you).'; exit 1 }
}
if ($Code -notmatch $CodeRe) {
    Write-Host 'The code does not look right. It has the form xxxx-xxxx-xxxx (letters and digits, no 0, o, 1, l, i).'
    exit 1
}
Write-Host "user: $User"

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
    Write-Host '--- public key ---'
    Write-Host $PubKey
    exit 0
}

# ---- 4. register the key with the server ----
Step 4 "Registering your key at $WebUrl/join"
$payload = (@{ user = $User; code = $Code; pubkey = $PubKey } | ConvertTo-Json -Compress)
$status = 0
$respText = ''
$curlExe = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($curlExe) {
    # Resolve the web host to HostIp ourselves: some ISP resolvers block sslip.io. HTTPS stays valid.
    $webHost = ([System.Uri]$WebUrl).Host
    $bodyFile = [System.IO.Path]::GetTempFileName()
    $respFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllBytes($bodyFile, (New-Object System.Text.UTF8Encoding($false)).GetBytes($payload))
        $argLine = '-sS --max-time 20 --resolve ' + (Q "${webHost}:443:$HostIp") + ' -o ' + (Q $respFile) +
            ' -w "%{http_code}" -H "Content-Type: application/json" --data-binary ' + (Q "@$bodyFile") + ' ' + (Q "$WebUrl/join")
        $r = Invoke-Native $curlExe.Source $argLine -Capture
        $code = 0
        [void][int]::TryParse(($r.Out -replace '\D', ''), [ref]$code)
        $status = $code
        if (Test-Path $respFile) { $respText = [System.IO.File]::ReadAllText($respFile) }
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $bodyFile, $respFile
    }
} else {
    try {
        $resp = Invoke-WebRequest -Uri "$WebUrl/join" -Method Post -ContentType 'application/json' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 20 -UseBasicParsing
        $status = [int]$resp.StatusCode
        $respText = [string]$resp.Content
    } catch {
        $ex = $_.Exception
        if ($ex.Response) {
            $status = [int]$ex.Response.StatusCode
            try {
                $sr = New-Object System.IO.StreamReader($ex.Response.GetResponseStream())
                $respText = $sr.ReadToEnd()
            } catch { }
        }
    }
}
switch ($status) {
    200 {
        if ($respText -match '"added"\s*:\s*true') { Write-Host 'key registered' } else { Write-Host 'key was already registered' }
    }
    403 { Write-Host 'Wrong user or code. Check the message Alvaro sent you and run again.'; exit 1 }
    429 { Write-Host 'Too many failed tries from your network. Wait 10 minutes and run again.'; exit 1 }
    400 { Write-Host "The server rejected the request: $($respText.Trim())"; exit 1 }
    0 {
        Write-Host "Cannot reach $WebUrl. Check your internet connection, or ask Alvaro whether the server is up"
        Write-Host '(the first HTTPS certificate can take about 30 s after setup).'
        exit 1
    }
    default { Write-Host "Unexpected answer from the server (HTTP $status): $($respText.Trim())"; exit 1 }
}

# ---- 5. ssh config ----
Step 5 "Updating $SshDir\config"
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

# ---- 6. test ----
Step 6 "Testing ssh $HostAlias"
$ok = $false
for ($i = 1; $i -le 3; $i++) {
    if (Test-Ssh) { $ok = $true; break }
    if ($i -lt 3) { Write-Host "not yet (try $i of 3), retrying in 3 s..."; Start-Sleep -Seconds 3 }
}
if (-not $ok) {
    Write-Host "Your key is registered but ssh $HostAlias does not work from this computer."
    Write-Host "Try: ssh -v $HostAlias true  (a firewall or school/corporate network may block port $SshPort; try a phone hotspot)."
    exit 1
}

# ---- 7. local project clone ----
function Setup-Project([string]$Url, [string]$Dir, [string]$UserName, [string]$TeamFile) {
    # Returns a one-line status for the summary ('' = not set up).
    $isRepo = Test-Path (Join-Path $Dir '.git')
    $isEmpty = (-not (Test-Path $Dir)) -or ((Test-Path $Dir -PathType Container) -and -not (Get-ChildItem -Force $Dir | Select-Object -First 1))
    $msg = ''
    $origin = ''
    if ($isRepo) { $origin = (Invoke-Native 'git' ('-C ' + (Q $Dir) + ' remote get-url origin') -Capture).Out }
    if ($isEmpty) {
        $r = Invoke-Native 'git' ('clone -q ' + (Q $Url) + ' ' + (Q $Dir))
        if ($r.ExitCode -eq 0) { Write-Host "cloned $Url"; $msg = "$Dir (cloned)" }
        else { Write-Host "WARNING: could not clone $Url (the server's project repo may not exist yet: ask Alvaro, then re-run this script)." }
    } elseif ($isRepo -and $origin -eq $Url) {
        $r = Invoke-Native 'git' ('-C ' + (Q $Dir) + ' fetch -q')
        if ($r.ExitCode -eq 0) { Write-Host 'already cloned, fetched'; $msg = "$Dir (up to date, fetched)" }
        else { Write-Host "WARNING: git fetch failed in $Dir"; $msg = "$Dir (fetch failed)" }
    } else {
        Write-Host "WARNING: $Dir exists but is not a clone of $Url; leaving it alone."
        Write-Host '         Use -ProjectDir <other folder> or -NoProject.'
        return ''
    }
    if ((Test-Path (Join-Path $Dir '.git')) -and ((Invoke-Native 'git' ('-C ' + (Q $Dir) + ' remote get-url origin') -Capture).Out -eq $Url)) {
        $display = ''
        foreach ($line in [System.IO.File]::ReadAllLines($TeamFile)) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) {
                $parts = $t -split '\s+', 2
                if ($parts[0] -eq $UserName -and $parts.Count -gt 1) { $display = $parts[1]; break }
            }
        }
        if (-not $display) { $display = $UserName }
        if (-not (Invoke-Native 'git' 'config --global user.name' -Capture).Out) {
            Invoke-Native 'git' ('-C ' + (Q $Dir) + ' config user.name ' + (Q $display)) | Out-Null
            Write-Host "git user.name set for this project: $display"
        }
        if (-not (Invoke-Native 'git' 'config --global user.email' -Capture).Out) {
            Invoke-Native 'git' ('-C ' + (Q $Dir) + ' config user.email ' + (Q "$UserName@hackathon.local")) | Out-Null
            Write-Host "git user.email set for this project: $UserName@hackathon.local"
        }
    }
    return $msg
}

$ProjectMsg = 'skipped (-NoProject)'
if (-not $NoProject) {
    $ProjectUrl = $env:HACK_PROJECT_URL
    if (-not $ProjectUrl) { $ProjectUrl = "${HostAlias}:/srv/hack/project.git" }
    if ($ProjectDir) {
        $ProjectPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($OrigDir, $ProjectDir))
    } else {
        $ProjectPath = Join-Path (Split-Path -Parent $Root) 'hackathon'
    }
    Step 7 "Team project in $ProjectPath"
    if (-not (Has-Command 'git')) {
        Write-Host 'WARNING: git is not installed, so the project was not cloned. Install Git for Windows and re-run.'
        $ProjectMsg = ''
    } else {
        $ProjectMsg = Setup-Project $ProjectUrl $ProjectPath $User $teamPath
    }
}
if (-not $ProjectMsg) { $ProjectMsg = 'not set up (see warning above)' }

Write-Host ''
Write-Host "You are connected as $User."
Write-Host "  ssh $HostAlias                  open a shell on the VPS"
Write-Host ''
Write-Host "Web (login: user = $User, password = your code)"
Write-Host "  $WebUrl           web file explorer: upload and download files"
Write-Host ''
Write-Host "Local project folder:    $ProjectMsg"
Write-Host ''
Write-Host 'How we work'
Write-Host '  1. Code with your own agent in that folder (nobody runs agents on the VPS: 6 GB RAM for 4 people).'
Write-Host "  2. git pull --rebase; git push   (origin = the VPS; a push to main updates ~/hack/project on the VPS"
Write-Host "     and mirrors to GitHub $ProjectRepo; use branches <you>/<feature> for work in progress)"
Write-Host "  3. Big files and data: .\send.ps1 <paths>   (macOS/Linux/Git Bash: ./send.sh <paths>)  -> ~/hack/inbox/$User/"
Write-Host ''
Write-Host "VS Code / Cursor on the VPS files: Remote-SSH, connect to host `"$HostAlias`""
Write-Host "Shared terminal:         run 'pair' on the VPS"
exit 0
