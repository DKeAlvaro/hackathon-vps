# Send files or folders to the shared VPS: .\send.ps1 <paths...>
# They land in ~/hack/inbox/<you>/ on the VPS (= /srv/hack/inbox/<you>/).
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Paths)

if (-not $Paths -or $Paths.Count -eq 0) { Write-Host 'Usage: .\send.ps1 <path> [path...]'; exit 2 }
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = $HOME }
$Cfg = Join-Path $UserHome '.ssh\config'
$User = ''
if (Test-Path $Cfg) {
    $inBlock = $false
    foreach ($line in [System.IO.File]::ReadAllLines($Cfg)) {
        if ($line.Trim() -eq '# >>> hackathon-vps >>>') { $inBlock = $true; continue }
        if ($line.Trim() -eq '# <<< hackathon-vps <<<') { $inBlock = $false }
        if ($inBlock -and $line -match '^\s*User\s+(\S+)') { $User = $Matches[1]; break }
    }
}
if (-not $User) { Write-Host "No hack block in $Cfg. Run connect.ps1 first."; exit 1 }

$resolved = @()
foreach ($p in $Paths) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "Not found: $p"; exit 1 }
    $resolved += (Resolve-Path -LiteralPath $p).ProviderPath
}

$argList = @('-r', '--') + $resolved + @("hack:hack/inbox/$User/")
& scp @argList
if ($LASTEXITCODE -ne 0) { Write-Host 'scp failed.'; exit 1 }
# scp keeps the source mode (e.g. 644): make the copies group-writable so teammates can edit them.
foreach ($r in $resolved) {
    $name = Split-Path -Leaf $r
    $dest = "hack/inbox/$User/$name"
    $q = "'" + ($dest -replace "'", "'\''") + "'"
    & ssh hack "chmod -R g+rwX $q"
    if ($LASTEXITCODE -ne 0) { Write-Host "warning: could not chmod $dest" }
}
Write-Host "Sent. On the VPS: ~/hack/inbox/$User/   (browse it with Files or Code on the web page)"
