# AgentHub Remote Helper (Windows)
# Runs hidden in the signed-in user's own desktop session (started by a scheduled task at logon).
# Screenshots and anything that needs the user's desktop must run here, not in the SSH session.
# It runs ONLY jobs that carry a valid signature from the operator key. The list of allowed signers
# is in a folder that only administrators can change.
param([switch]$Once)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$HelperVersion = 1
$Base = if ($env:AGENTHUB_BASE) { $env:AGENTHUB_BASE } else { Join-Path $env:ProgramData 'AgentHubRemote' }
$Jobs = Join-Path (Join-Path $Base 'ipc') 'jobs'
$Signers = Join-Path $Base 'allowed_signers'
$SshKeygen = if ($env:AGENTHUB_SSH_KEYGEN) { $env:AGENTHUB_SSH_KEYGEN } else { Join-Path $Base 'openssh\ssh-keygen.exe' }
$PsExe = if ($env:AGENTHUB_PS) { $env:AGENTHUB_PS } else { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$MaxSeconds = 90
$MaxOutBytes = 8MB

function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    return '"' + $a.Replace('"', '\"') + '"'
}

# Runs a program, optionally feeding it exact bytes on stdin. Returns code, stdout bytes, stderr bytes.
function Invoke-Native([string]$Exe, [string[]]$Arguments, [byte[]]$StdIn, [int]$TimeoutSec) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $so = New-Object System.IO.MemoryStream
    $se = New-Object System.IO.MemoryStream
    $t1 = $p.StandardOutput.BaseStream.CopyToAsync($so)
    $t2 = $p.StandardError.BaseStream.CopyToAsync($se)
    try {
        if ($StdIn -and $StdIn.Length -gt 0) { $p.StandardInput.BaseStream.Write($StdIn, 0, $StdIn.Length) }
        $p.StandardInput.Close()
    } catch { }
    $code = 124
    if ($p.WaitForExit($TimeoutSec * 1000)) {
        $code = $p.ExitCode
        [void]$t1.Wait(5000); [void]$t2.Wait(5000)
    } else {
        try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
        try { $p.Kill() } catch { }
    }
    return @{ Code = $code; Out = $so.ToArray(); Err = $se.ToArray() }
}

function Write-Result([string]$Id, [int]$Rc, [byte[]]$Out) {
    if ($Out.Length -gt $MaxOutBytes) { $Out = $Out[0..($MaxOutBytes - 1)] }
    $json = '{"rc":' + $Rc + ',"out":"' + [Convert]::ToBase64String($Out) + '"}'
    $tmp = Join-Path $Jobs ($Id + '.out.tmp')
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::ASCII)
    Move-Item -LiteralPath $tmp -Destination (Join-Path $Jobs ($Id + '.out')) -Force
}

function Invoke-Job([System.IO.FileInfo]$JobFile) {
    $id = [System.IO.Path]::GetFileNameWithoutExtension($JobFile.Name)
    if ($id -notmatch '^[0-9a-f]{16}$') { Remove-Item -LiteralPath $JobFile.FullName -Force -ErrorAction SilentlyContinue; return }
    $sigFile = Join-Path $Jobs ($id + '.sig')
    if (-not (Test-Path -LiteralPath $sigFile)) {
        # the signature arrives just after the job; give up on jobs that never get one
        if (((Get-Date) - $JobFile.LastWriteTime).TotalSeconds -gt 60) { Remove-Item -LiteralPath $JobFile.FullName -Force -ErrorAction SilentlyContinue }
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($JobFile.FullName)
    $enc = [System.Text.Encoding]::ASCII
    $v = Invoke-Native $SshKeygen @('-Y', 'verify', '-f', $Signers, '-I', 'hermes', '-n', 'hermes-remote-job', '-s', $sigFile) $bytes 20
    Remove-Item -LiteralPath $JobFile.FullName, $sigFile -Force -ErrorAction SilentlyContinue
    if ($v.Code -ne 0) { Write-Result $id 126 $enc.GetBytes('rejected: bad or missing signature'); return }
    try { $job = $enc.GetString($bytes) | ConvertFrom-Json } catch { Write-Result $id 126 $enc.GetBytes('rejected: unreadable job'); return }
    $now = [int]([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds
    if ($job.id -ne $id -or [math]::Abs($now - [int]$job.ts) -gt 600 -or -not ($job.cmd -is [string])) {
        Write-Result $id 126 $enc.GetBytes('rejected: stale or mismatched job'); return
    }
    $script = '$ProgressPreference=''SilentlyContinue'';' + $job.cmd + "`n" + 'if ($LASTEXITCODE) { exit $LASTEXITCODE }'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    $r = Invoke-Native $PsExe @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $encoded) $null $MaxSeconds
    Write-Result $id $r.Code ([byte[]]($r.Out + $r.Err))
}

function Write-Status {
    $s = "helper_version=$HelperVersion`nuser=$env:USERNAME`nsession=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)`npid=$PID`ntime=$((Get-Date).ToString('s'))`n"
    try { [System.IO.File]::WriteAllText((Join-Path (Join-Path $Base 'ipc') 'status.txt'), $s) } catch { }
}

if (-not $Once) {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\AgentHubRemoteHelper', [ref]$created)
    if (-not $created) { return }   # one helper per desktop session
}
$lastStatus = [DateTime]::MinValue
do {
    if (((Get-Date) - $lastStatus).TotalSeconds -ge 30) { Write-Status; $lastStatus = Get-Date }
    if (Test-Path -LiteralPath $Jobs) {
        Get-ChildItem -LiteralPath $Jobs -Filter '*.job' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object {
            try { Invoke-Job $_ } catch { try { Write-Result ([System.IO.Path]::GetFileNameWithoutExtension($_.Name)) 125 ([System.Text.Encoding]::ASCII.GetBytes("helper error: $($_.Exception.Message)")) } catch { } }
        }
    }
    if ($Once) { break }
    Start-Sleep -Seconds 1
} while ($true)
