<#
.SYNOPSIS
  Scheduled watchdog for a CLI-launched Qt browser.
  - Runs the browser only 08:30-18:00, Mon-Fri.
  - Restarts it if it exits, crashes, or (optionally) hangs during that window.
  - Closes it outside the window.
  Designed to run continuously in the interactive user session.
#>

param(
    [string]$ExePath   = "uv",
    [string[]]$Arguments = @("run", "holly"),

    # Directory to run the command from (the path you normally cd into)
    [string]$WorkDir   = "C:\code\holly\projects\holly-local",

    # Active window (24h). Browser runs only inside this, on weekdays.
    [string]$StartTime = "08:30",
    [string]$EndTime   = "18:00",

    [int]$PollSeconds = 3,

    [switch]$DetectHang,
    [int]$HangGraceSeconds = 30,

    [int]$MaxRestarts = 5,
    [int]$RestartWindowSeconds = 60,
    [int]$BackoffSeconds = 60,

    [string]$LogPath = "C:\Watchdog\qtbrowser-watchdog.log"
)

$ErrorActionPreference = 'Stop'

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0}  [{1}]  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LogPath -Value $line } catch {}
    Write-Host $line
}

function In-ActiveWindow {
    $now = Get-Date
    if ($now.DayOfWeek -eq 'Saturday' -or $now.DayOfWeek -eq 'Sunday') { return $false }
    $start = [datetime]::ParseExact($StartTime, 'HH:mm', $null)
    $end   = [datetime]::ParseExact($EndTime,   'HH:mm', $null)
    $start = [datetime]::Today.Add($start.TimeOfDay)
    $end   = [datetime]::Today.Add($end.TimeOfDay)
    return ($now -ge $start -and $now -lt $end)
}

function Stop-Tree {
    param([int]$ProcId)
    try { Start-Process taskkill -ArgumentList "/PID $ProcId /T /F" -Wait -NoNewWindow -ErrorAction SilentlyContinue } catch {}
}

function Stop-Target {
    param($Proc)
    if ($null -eq $Proc) { return }
    try { $Proc.Refresh(); if ($Proc.HasExited) { return } } catch { return }
    Write-Log "Closing browser (PID $($Proc.Id)) - outside active hours."
    try { $Proc.CloseMainWindow() | Out-Null } catch {}
    Start-Sleep -Seconds 5
    try { $Proc.Refresh(); if (-not $Proc.HasExited) { Stop-Tree -ProcId $Proc.Id } } catch { Stop-Tree -ProcId $Proc.Id }
}

function Start-Target {
    Write-Log "Launching: `"$ExePath`" $($Arguments -join ' ')"
    try {
        $p = Start-Process -FilePath $ExePath -ArgumentList $Arguments -WorkingDirectory $WorkDir -PassThru
        Start-Sleep -Milliseconds 500
        Write-Log "Started. PID: $($p.Id)"
        return $p
    } catch {
        Write-Log "Failed to launch: $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

Write-Log "===== Watchdog starting ====="
Write-Log "Target: $ExePath $($Arguments -join ' ') | WorkDir: $WorkDir | Hours: $StartTime-$EndTime Mon-Fri | HangDetect: $DetectHang"
if (($ExePath -match '[\\/:]') -and -not (Test-Path $ExePath)) { Write-Log "Executable not found: $ExePath" 'ERROR'; exit 1 }
if (-not (Test-Path $WorkDir)) { Write-Log "Working directory not found: $WorkDir" 'ERROR'; exit 1 }

$restartTimes = @()
$proc = $null

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    if (-not (In-ActiveWindow)) {
        if ($proc) { Stop-Target -Proc $proc; $proc = $null; $restartTimes = @() }
        continue
    }

    # ---- inside active hours: keep it running ----
    if ($proc) { try { $proc.Refresh() } catch {} }

    $needsRestart = $false; $reason = ''

    if ($null -eq $proc -or $proc.HasExited) {
        $needsRestart = $true
        $code = 'n/a'; if ($proc) { try { $code = $proc.ExitCode } catch { $code = 'unknown' } }
        $reason = "not running (exit code: $code)"
    }
    elseif ($DetectHang -and $proc.MainWindowHandle -ne 0 -and -not $proc.Responding) {
        $stillHung = $true; $deadline = (Get-Date).AddSeconds($HangGraceSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            try { $proc.Refresh() } catch {}
            if ($proc.HasExited)  { $stillHung = $false; break }
            if ($proc.Responding) { $stillHung = $false; break }
        }
        if ($stillHung -and -not $proc.HasExited) {
            Write-Log "Window unresponsive for ${HangGraceSeconds}s. Killing PID $($proc.Id)." 'WARN'
            Stop-Tree -ProcId $proc.Id; $needsRestart = $true; $reason = "window hung"
        }
    }

    if ($needsRestart) {
        Write-Log "Restart triggered: $reason" 'WARN'
        $now = Get-Date
        $restartTimes += $now
        $cutoff = $now.AddSeconds(-$RestartWindowSeconds)
        $restartTimes = @($restartTimes | Where-Object { $_ -ge $cutoff })
        if ($restartTimes.Count -gt $MaxRestarts) {
            Write-Log ("Restart storm: {0} in {1}s. Backing off {2}s." -f $restartTimes.Count, $RestartWindowSeconds, $BackoffSeconds) 'ERROR'
            Start-Sleep -Seconds $BackoffSeconds; $restartTimes = @()
        }
        $proc = Start-Target
    }
}