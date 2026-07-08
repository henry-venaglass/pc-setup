<#
.SYNOPSIS
    Retrofit an ALREADY-PROVISIONED Holly PC onto AWS (Greengrass) - for PCs
    set up before setup.ps1 gained sections 21/22. New PCs never need this.

    Does exactly two things, matching setup.ps1 21/22 (keep them in sync):
      1. Installs the watchdog launcher + Holly-Watchdog logon task
         (without it, code delivered by Greengrass would never launch)
      2. Enrols the PC into Greengrass as holly-<PCNumber> in holly-fleet

.USAGE
    Run in an ADMIN PowerShell on the PC:
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
      .\aws_onboard.ps1 -PCNumber 001 -AwsAccessKey "AKIA..." -AwsSecretKey "..."

    Afterwards: PC shows Healthy under Greengrass -> Core devices, and pulls
    the fleet's current deployment into C:\code\holly automatically.
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d{3}$')]
    [string]$PCNumber,

    [Parameter(Mandatory=$true)]
    [string]$AwsAccessKey,

    [Parameter(Mandatory=$true)]
    [string]$AwsSecretKey
)

$AwsRegion  = "eu-west-2"
$ThingName  = "holly-$PCNumber"
$ThingGroup = "holly-fleet"
$GgcUser    = "ggc_user"

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Must run as Administrator." -ForegroundColor Red
    exit 1
}

function Write-Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }

# ============================================================================
# 1. WATCHDOG LAUNCHER + LOGON TASK  (same as setup.ps1 section 21)
# ============================================================================
Write-Step "Installing watchdog launcher + logon task"

New-Item -Path "C:\code" -ItemType Directory -Force | Out-Null

$LauncherScript = @'
# Holly watchdog launcher - stable shim registered as holly's logon task.
# The real logic is C:\code\holly\watchdog.ps1, which arrives (and updates)
# with every app release. Keep this file logic-free: it only changes by
# re-running setup.ps1 on the machine.
$wd = "C:\code\holly\watchdog.ps1"
while ($true) {
    if (Test-Path $wd) {
        # Blocks while the watchdog runs. The watchdog exits on purpose when
        # a release replaces its file; looping relaunches the new version.
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wd
    }
    Start-Sleep -Seconds 15
}
'@
Set-Content -Path "C:\code\watchdog-launcher.ps1" -Value $LauncherScript -Encoding UTF8 -Force

$wdAction = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\code\watchdog-launcher.ps1'
$wdTrigger = New-ScheduledTaskTrigger -AtLogOn -User "holly"
$wdPrincipal = New-ScheduledTaskPrincipal -UserId "holly" -LogonType Interactive
$wdSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "Holly-Watchdog" -Action $wdAction -Trigger $wdTrigger `
    -Principal $wdPrincipal -Settings $wdSettings -Force | Out-Null
Write-Host "    Holly-Watchdog task registered (starts at holly's next logon)"

# ============================================================================
# 2. GREENGRASS ENROLMENT  (same as setup.ps1 section 22)
# ============================================================================
Write-Step "Installing Java runtime (Amazon Corretto)"
$java = Get-ChildItem "$env:ProgramFiles\Amazon Corretto\*\bin\java.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $java) {
    # Direct MSI from Amazon - no winget dependency
    $msi = "$env:TEMP\corretto11.msi"
    Invoke-WebRequest -Uri "https://corretto.aws/downloads/latest/amazon-corretto-11-x64-windows-jdk.msi" -OutFile $msi -UseBasicParsing
    $p = Start-Process msiexec.exe -ArgumentList "/i", "`"$msi`"", "/qn" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Corretto MSI install returned exit code $($p.ExitCode)" }
    $java = Get-ChildItem "$env:ProgramFiles\Amazon Corretto\*\bin\java.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $java) { throw "java.exe not found after Corretto install" }
Write-Host "    java: $($java.FullName)"

Write-Step "Creating component user '$GgcUser'"
$ggcPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
# New-LocalUser/Set-LocalUser, NOT net.exe - net user prompts interactively
# on passwords >14 chars and hangs the script
$securePw = ConvertTo-SecureString $ggcPassword -AsPlainText -Force
if (Get-LocalUser -Name $GgcUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $GgcUser -Password $securePw   # reset so the stored credential below matches
} else {
    New-LocalUser -Name $GgcUser -Password $securePw | Out-Null
}
Set-LocalUser -Name $GgcUser -PasswordNeverExpires $true

# The Greengrass service runs as SYSTEM and reads this credential from
# SYSTEM's vault - so cmdkey must run as SYSTEM, via PsExec.
Write-Step "Storing credential for the Greengrass service (PsExec as SYSTEM)"
$psToolsZip = "$env:TEMP\PSTools.zip"
$psToolsDir = "$env:TEMP\PSTools"
Invoke-WebRequest -Uri "https://download.sysinternals.com/files/PSTools.zip" -OutFile $psToolsZip -UseBasicParsing
Expand-Archive $psToolsZip $psToolsDir -Force
& "$psToolsDir\PsExec.exe" -accepteula -nobanner -s cmd /c "cmdkey /generic:$GgcUser /user:$GgcUser /pass:$ggcPassword" 2>$null
if ($LASTEXITCODE -ne 0) { throw "psexec/cmdkey returned exit code $LASTEXITCODE" }

& icacls "C:\code" /grant "${GgcUser}:(OI)(CI)M" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls returned exit code $LASTEXITCODE" }

Write-Step "Installing Greengrass Core + enrolling as $ThingName"
$ggZip = "$env:TEMP\greengrass-nucleus.zip"
$ggDir = "$env:TEMP\GreengrassInstaller"
Invoke-WebRequest -Uri "https://d2s8p88vqu9w66.cloudfront.net/releases/greengrass-nucleus-latest.zip" -OutFile $ggZip -UseBasicParsing
Expand-Archive $ggZip $ggDir -Force

$env:AWS_ACCESS_KEY_ID     = $AwsAccessKey
$env:AWS_SECRET_ACCESS_KEY = $AwsSecretKey
try {
    & $java.FullName "-Droot=C:\greengrass\v2" "-Dlog.store=FILE" `
        -jar "$ggDir\lib\Greengrass.jar" `
        --aws-region $AwsRegion `
        --thing-name $ThingName `
        --thing-group-name $ThingGroup `
        --component-default-user $GgcUser `
        --provision true `
        --setup-system-service true
    if ($LASTEXITCODE -ne 0) { throw "Greengrass installer returned exit code $LASTEXITCODE" }
} finally {
    # provisioning keys must not linger on the device
    Remove-Item Env:\AWS_ACCESS_KEY_ID, Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
}

Write-Step "Checking the Greengrass service"
$svc = Get-Service -Name "greengrass" -ErrorAction SilentlyContinue
if (-not $svc) { throw "greengrass service not found" }
if ($svc.Status -ne "Running") { Start-Service -Name "greengrass" }
& sc.exe failure greengrass reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

Write-Host ""
Write-Host "Done. $ThingName should show Healthy under AWS IoT -> Greengrass -> Core devices." -ForegroundColor Green
Write-Host "The fleet's current deployment (app + watchdog) will arrive in C:\code\holly within a few minutes."
Write-Host "The watchdog starts at holly's next logon - reboot when convenient." -ForegroundColor Green
