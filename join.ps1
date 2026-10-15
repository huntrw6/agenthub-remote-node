# join.ps1: set up this Windows PC for remote support.
#
#   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/huntrw6/agenthub-remote-node/main/join.ps1 | iex
#
# There is no code to type. At the end the PC shows an approval code; read it to the person who
# sent you here. Nothing works until they approve that code. This script:
#   0. looks up the newest commit on main and uses ONLY that commit for every file below
#      (to use a fixed version instead, set $env:HR_JOIN_BASE to its raw URL first),
#   1. detects 64-bit or 32-bit Windows,
#   2. downloads the installer parts and checks them against MANIFEST.sha256,
#   3. fills in the public relay settings,
#   4. runs the guided installer. Nothing is installed until it asks you and you agree.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Stop-Join([string]$m) { Write-Host ("join: " + $m) -ForegroundColor Red; throw $m }

$repo = if ($env:HR_REPO) { $env:HR_REPO } else { 'huntrw6/agenthub-remote-node' }
$base = $env:HR_JOIN_BASE
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Bytes([string]$url) {
    $wc = New-Object System.Net.WebClient
    try { return $wc.DownloadData($url) } finally { $wc.Dispose() }
}

if (-not $base) {
    if ($env:HR_SHA_OVERRIDE) { $sha = $env:HR_SHA_OVERRIDE }
    else {
        $req = [System.Net.WebRequest]::Create("https://api.github.com/repos/$repo/commits/main")
        $req.UserAgent = 'agenthub-join'; $req.Accept = 'application/vnd.github.sha'; $req.Timeout = 30000
        try { $resp = $req.GetResponse(); $sr = New-Object System.IO.StreamReader($resp.GetResponseStream()); $sha = $sr.ReadToEnd().Trim(); $sr.Close(); $resp.Close() }
        catch { Stop-Join 'could not look up the newest version (check the internet connection)' }
    }
    if ($sha -notmatch '^[0-9a-f]{40}$') { Stop-Join 'unexpected answer while looking up the newest version.' }
    $base = "https://raw.githubusercontent.com/$repo/$sha"
}
if ($base -notmatch '^https://raw\.githubusercontent\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/[0-9a-f]{40}$' -and $env:HR_TEST -ne '1') {
    Stop-Join 'the base address must be a raw.githubusercontent.com address pinned to a 40-character commit.'
}

$type = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
Write-Host ("Detected Windows type: " + $type)

$files = @('installer/win-installer.ps1.tmpl', 'installer/win-helper.ps1', 'config/relay.env')
$data = @{}
try { $data['MANIFEST.sha256'] = Get-Bytes "$base/MANIFEST.sha256" } catch { Stop-Join 'could not download MANIFEST.sha256 (check the internet connection)' }
foreach ($f in $files) {
    try { $data[$f] = Get-Bytes "$base/$f" } catch { Stop-Join "could not download $f (check the internet connection)" }
}

# every downloaded part must be listed in the manifest and match it
$manifest = @{}
foreach ($line in ([System.Text.Encoding]::UTF8.GetString($data['MANIFEST.sha256']) -split "`n")) {
    if ($line -match '^([0-9a-f]{64})  (\S+)\s*$') { $manifest[$Matches[2]] = $Matches[1] }
}
foreach ($f in $files) {
    if (-not $manifest.ContainsKey($f)) { Stop-Join "MANIFEST.sha256 does not list $f; stopping." }
    $h = [System.Security.Cryptography.SHA256]::Create()
    $got = (($h.ComputeHash($data[$f]) | ForEach-Object { $_.ToString('x2') }) -join '')
    if ($got -ne $manifest[$f]) { Stop-Join "downloaded files do not match MANIFEST.sha256 ($f); stopping." }
}

# settings: KEY='value' lines written by hermes-remote export-config (values are shell-quoted)
$cfg = @{}
foreach ($line in ([System.Text.Encoding]::UTF8.GetString($data['config/relay.env']) -split "`n")) {
    if ($line -match "^([A-Z0-9_]+)=(.*)$") {
        $v = $Matches[2].Trim()
        if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) { $v = $v.Substring(1, $v.Length - 2).Replace("'\''", "'") }
        $cfg[$Matches[1]] = $v
    }
}
foreach ($k in 'RELAY_HOST', 'RELAY_PORT', 'RELAY_USER', 'RELAY_HOSTKEY', 'HERMES_PUB', 'JOIN_KEY_B64') {
    if (-not $cfg[$k]) { Stop-Join 'config/relay.env is incomplete.' }
}
if ($cfg['RELAY_HOST'] -notmatch '^[A-Za-z0-9.-]+$' -or $cfg['RELAY_PORT'] -notmatch '^\d+$' -or $cfg['RELAY_USER'] -notmatch '^[a-z_][a-z0-9_-]*$') { Stop-Join 'config/relay.env has unexpected values.' }

function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
$owner = if ($cfg['OWNER']) { $cfg['OWNER'] } else { 'the support person' }
$subs = @{
    TYPE = $type; OWNER = $owner; DATE = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); EXPIRES = 'the owner turns the join link off'
    RELAY_HOST = $cfg['RELAY_HOST']; RELAY_PORT = $cfg['RELAY_PORT']; RELAY_USER = $cfg['RELAY_USER']; RELAY_HOSTKEY = $cfg['RELAY_HOSTKEY']
    HERMES_PUB = $cfg['HERMES_PUB']; JOIN_MODE = '1'; ENROLL_KEY_B64 = $cfg['JOIN_KEY_B64']
    HELPER_B64 = [Convert]::ToBase64String($data['installer/win-helper.ps1'])
}
$tmpl = [System.Text.Encoding]::UTF8.GetString($data['installer/win-installer.ps1.tmpl'])
$missing = New-Object System.Collections.ArrayList
$script = [regex]::Replace($tmpl, '@@([A-Z0-9_]+)@@', { param($m) if ($subs.ContainsKey($m.Groups[1].Value)) { Q $subs[$m.Groups[1].Value] } else { [void]$missing.Add($m.Groups[1].Value); '' } })
if ($missing.Count -gt 0) { Stop-Join ('no value for ' + ($missing -join ', ')) }
if ($script.Contains('@@')) { Stop-Join 'installer still has unfilled placeholders.' }

$tmpDir = Join-Path $env:TEMP ('agenthub-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
$ps1 = Join-Path $tmpDir 'install.ps1'
[System.IO.File]::WriteAllText($ps1, $script, (New-Object System.Text.UTF8Encoding($true)))

$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errs)
if ($errs -and $errs.Count -gt 0) { Stop-Join 'the prepared installer has a syntax error.' }

# test hook: HR_JOIN_STOP_AT=<path> saves the prepared installer there and stops
if ($env:HR_JOIN_STOP_AT) { Copy-Item -LiteralPath $ps1 -Destination $env:HR_JOIN_STOP_AT -Force; return }

Write-Host "Prepared the $type installer. Starting the guided setup."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1
Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
