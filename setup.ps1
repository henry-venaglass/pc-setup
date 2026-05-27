<#
.SYNOPSIS
    Automated setup script for Holly NUC PCs.

.DESCRIPTION
    Runs after Windows OOBE is complete. Configures the machine to match
    the Holly-spec build: debloated, locked down, with required apps installed.

    Reports a summary at the end showing how many steps passed, warned, or failed,
    and writes a status file to C:\code\setup-status.json for fleet-wide auditing.

.USAGE
    1. Complete Windows OOBE manually (say no to everything, username "holly", password "holly").
    2. Plug in ethernet.
    3. Open PowerShell AS ADMINISTRATOR.
    4. If script is blocked: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    5. Run: .\Setup-HollyPC.ps1 -PCNumber 001 -AuthKey "tskey-auth-..."

       (omit -AuthKey to install Tailscale but sign in manually later)

.PARAMETER PCNumber
    Three-digit number for this PC, used in hostname HOLLY-NNN. e.g. "001", "002"

.PARAMETER AuthKey
    Optional. Tailscale auth key for unattended sign-in. Generate from:
    https://login.tailscale.com/admin/settings/keys (reusable, pre-approved, tagged)
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d{3}$')]
    [string]$PCNumber,

    [Parameter(Mandatory=$false)]
    [string]$AuthKey = ""
)

# ============================================================================
# CONFIG - edit these before running on the first PC
# ============================================================================
$HollyPassword     = "holly"   # Password for the Holly user (must match what was typed in OOBE)
$TightVNCPassword  = "holly"   # VNC connection password (max 8 chars for legacy clients)
$NewHostname       = "HOLLY-$PCNumber"

# ----- Tailscale -----
# Auth key is passed as a script parameter rather than stored in the file, so the
# script can live on GitHub / shared USB sticks without leaking tailnet credentials.
# Generate a reusable, pre-approved, tagged auth key from:
#   https://login.tailscale.com/admin/settings/keys
# Then pass it via: -AuthKey "tskey-auth-..."
# If you omit -AuthKey, the script will install Tailscale but you'll need to sign in manually.
$TailscaleAuthKey  = $AuthKey

# ============================================================================
# PRE-FLIGHT
# ============================================================================
$ErrorActionPreference = "Continue"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Must run as Administrator." -ForegroundColor Red
    exit 1
}

if ($HollyPassword -eq "CHANGE_ME_BEFORE_RUNNING") {
    Write-Host "ERROR: Edit the script and set HollyPassword and TightVNCPassword first." -ForegroundColor Red
    exit 1
}

# ============================================================================
# RESULT TRACKING + LOGGING HELPERS
# ============================================================================
# Every step records into one of three buckets:
#   Passed - worked as intended
#   Warned - non-critical issue, script continues
#   Failed - a hard requirement didn't work
#
# At the end we print a summary and write status to C:\code\setup-status.json

$Results = @{
    Passed   = [System.Collections.ArrayList]::new()
    Warned   = [System.Collections.ArrayList]::new()
    Failed   = [System.Collections.ArrayList]::new()
    Started  = Get-Date
}

function Write-Step($msg)   { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Detail($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Record-Pass($description) {
    Write-Host "    [PASS] $description" -ForegroundColor Green
    [void]$Results.Passed.Add($description)
}
function Record-Warn($description) {
    Write-Host "    [WARN] $description" -ForegroundColor Yellow
    [void]$Results.Warned.Add($description)
}
function Record-Fail($description) {
    Write-Host "    [FAIL] $description" -ForegroundColor Red
    [void]$Results.Failed.Add($description)
}

# Try-Step: run a script block and record the outcome.
# A thrown exception or explicit $false return = FAIL (or WARN if -WarnOnFail given).
# Anything else = PASS.
function Try-Step {
    param(
        [string]$Description,
        [scriptblock]$Action,
        [switch]$WarnOnFail
    )
    try {
        $result = & $Action
        if ($result -eq $false) {
            if ($WarnOnFail) { Record-Warn $Description } else { Record-Fail $Description }
        } else {
            Record-Pass $Description
        }
    } catch {
        $errMsg = $_.Exception.Message
        if ($WarnOnFail) { Record-Warn "$Description : $errMsg" }
        else             { Record-Fail "$Description : $errMsg" }
    }
}

Start-Transcript -Path "$env:USERPROFILE\Desktop\Setup-$NewHostname.log" -Append | Out-Null
Write-Host "`n=== Setting up $NewHostname ===" -ForegroundColor Magenta
Write-Host "Started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray

# ============================================================================
# 1. RENAME PC
# ============================================================================
Write-Step "Renaming computer to $NewHostname"
Try-Step "Computer renamed to $NewHostname" {
    if ($env:COMPUTERNAME -eq $NewHostname) {
        Write-Detail "Already named $NewHostname - no rename needed"
        return $true
    }
    Rename-Computer -NewName $NewHostname -Force -ErrorAction Stop
    Write-Detail "Rename queued (takes effect on reboot)"
}

# ============================================================================
# 2. CONFIGURE AUTO-LOGIN FOR HOLLY
# ============================================================================
Write-Step "Configuring auto-login for holly"
Try-Step "Auto-login configured" {
    if (-not (Get-LocalUser -Name "holly" -ErrorAction SilentlyContinue)) {
        throw "holly user not found - was the account created during OOBE?"
    }
    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $winlogon -Name "AutoAdminLogon"    -Value "1"     -ErrorAction Stop
    Set-ItemProperty -Path $winlogon -Name "DefaultUserName"   -Value "holly" -ErrorAction Stop
    Set-ItemProperty -Path $winlogon -Name "DefaultPassword"   -Value $HollyPassword -ErrorAction Stop
    Set-ItemProperty -Path $winlogon -Name "DefaultDomainName" -Value $env:COMPUTERNAME -ErrorAction Stop
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
        -Name "DisableCAD" -Value 1 -Type DWord -Force -ErrorAction Stop
}

# ============================================================================
# 3. UNINSTALL BLOATWARE
# ============================================================================
Write-Step "Uninstalling Microsoft Store bloatware"

$keep = @(
    "*Microsoft.WindowsStore*", "*Microsoft.DesktopAppInstaller*",
    "*Microsoft.WindowsNotepad*", "*Microsoft.WindowsTerminal*",
    "*Microsoft.VCLibs*", "*Microsoft.NET*", "*Microsoft.UI.Xaml*",
    "*Microsoft.WindowsCalculator*", "*Microsoft.Paint*", "*Microsoft.ScreenSketch*",
    "*Microsoft.SecHealthUI*", "*Microsoft.HEIFImageExtension*",
    "*Microsoft.HEVCVideoExtension*", "*Microsoft.VP9VideoExtensions*",
    "*Microsoft.WebMediaExtensions*", "*Microsoft.WebpImageExtension*",
    "*Microsoft.RawImageExtension*", "*Microsoft.AV1VideoExtension*",
    "*Microsoft.StorePurchaseApp*", "*Microsoft.Services.Store.Engagement*",
    "*Microsoft.UI.Xaml.CBS*", "*MicrosoftWindows.Client.CBS*",
    "*MicrosoftWindows.Client.WebExperience*", "*Windows.PrintDialog*",
    "*Microsoft.WindowsFeedbackHub*", "*Microsoft.LockApp*",
    "*Microsoft.AAD.BrokerPlugin*", "*Microsoft.Windows.Cortana*",
    "*Windows.CBSPreview*", "*Microsoft.MicrosoftEdgeDevToolsClient*",
    "*Microsoft.Win32WebViewHost*", "*Microsoft.Windows.AssignedAccessLockApp*",
    "*Microsoft.Windows.CapturePicker*", "*Microsoft.Windows.CloudExperienceHost*",
    "*Microsoft.Windows.ContentDeliveryManager*", "*Microsoft.Windows.OOBENetworkConnectionFlow*",
    "*Microsoft.Windows.OOBENetworkCaptivePortal*", "*Microsoft.Windows.ParentalControls*",
    "*Microsoft.Windows.PeopleExperienceHost*", "*Microsoft.Windows.PinningConfirmationDialog*",
    "*Microsoft.Windows.SecureAssessmentBrowser*", "*Microsoft.Windows.ShellExperienceHost*",
    "*Microsoft.Windows.StartMenuExperienceHost*", "*Microsoft.Windows.XGpuEjectDialog*",
    "*Microsoft.XboxGameCallableUI*", "*Microsoft.AccountsControl*",
    "*Microsoft.AsyncTextService*", "*Microsoft.BioEnrollment*",
    "*Microsoft.CredDialogHost*", "*Microsoft.ECApp*",
    "*Microsoft.LanguageExperiencePack*", "*Microsoft.WindowsAppRuntime*",
    "*Microsoft.WinAppRuntime*", "*NVIDIA*", "*AMD*", "*Realtek*", "*Intel*"
)

$allApps = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
$toRemove = $allApps | Where-Object {
    $name = $_.Name
    -not ($keep | Where-Object { $name -like $_ })
}

# Best-effort: many "system app" failures are expected; we count successes and skips.
$removed = 0
$skipped = 0
Write-Detail "Attempting to remove $($toRemove.Count) packages..."
foreach ($app in $toRemove) {
    try {
        Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
        $removed++
    } catch {
        $skipped++
    }
}

$provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
$provisionedRemoved = 0
foreach ($app in $provisioned) {
    $displayName = $app.DisplayName
    if (-not ($keep | Where-Object { $displayName -like $_.Trim('*') -or "*$displayName*" -like $_ })) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $app.PackageName -ErrorAction Stop | Out-Null
            $provisionedRemoved++
        } catch {}
    }
}

Write-Detail "Removed $removed apps + $provisionedRemoved provisioned (skipped $skipped system apps)"
if ($removed -ge 20) {
    Record-Pass "Bloatware removal ($removed apps, $provisionedRemoved provisioned)"
} elseif ($removed -ge 5) {
    Record-Warn "Bloatware removal lower than expected: only $removed apps removed"
} else {
    Record-Fail "Bloatware removal failed: only $removed apps removed (expected 20+)"
}

# ============================================================================
# 4. UNINSTALL ONEDRIVE
# ============================================================================
Write-Step "Removing OneDrive"
Try-Step "OneDrive uninstalled" {
    Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $oneDriveSetup = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($oneDriveSetup) {
        Start-Process $oneDriveSetup -ArgumentList "/uninstall" -Wait -NoNewWindow -ErrorAction Stop
    } else {
        Write-Detail "OneDriveSetup.exe not found - may already be uninstalled"
    }
    Remove-Item -Path "$env:USERPROFILE\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$env:PROGRAMDATA\Microsoft OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
    Get-ScheduledTask -TaskName "OneDrive*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($p in @(
        "HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
        "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
    )) {
        if (Test-Path $p) {
            Set-ItemProperty -Path $p -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# 5. WINDOWS UPDATE POLICY
# ============================================================================
Write-Step "Configuring Windows Update (manual install, active hours 06:00-22:00)"
Try-Step "Windows Update policy set" {
    $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $auPath = "$wuPath\AU"
    New-Item -Path $wuPath -Force -ErrorAction Stop | Out-Null
    New-Item -Path $auPath -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path $auPath -Name "AUOptions"                       -Value 2 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $auPath -Name "NoAutoUpdate"                    -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $auPath -Name "NoAutoRebootWithLoggedOnUsers"   -Value 1 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "ActiveHoursStart" -Value 6  -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "ActiveHoursEnd"   -Value 22 -Type DWord -Force -ErrorAction Stop
}

# ============================================================================
# 6. POWER SETTINGS
# ============================================================================
Write-Step "Setting power plan to never sleep / never screen off"
Try-Step "Power plan configured" {
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change disk-timeout-ac    0
    powercfg /change disk-timeout-dc    0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0
    powercfg /hibernate off
    if ($LASTEXITCODE -ne 0) { throw "powercfg returned exit code $LASTEXITCODE" }
}

# ============================================================================
# 7. APPEARANCE
# ============================================================================
Write-Step "Appearance: dark mode + black background + hide desktop icons"
Try-Step "Appearance configured" {
    $personalize = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not (Test-Path $personalize)) { New-Item -Path $personalize -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $personalize -Name "AppsUseLightTheme"    -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $personalize -Name "SystemUsesLightTheme" -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper"  -Value "" -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKCU:\Control Panel\Colors"  -Name "Background" -Value "0 0 0" -Force -ErrorAction Stop
    $dwm = "HKCU:\SOFTWARE\Microsoft\Windows\DWM"
    if (-not (Test-Path $dwm)) { New-Item -Path $dwm -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $dwm -Name "AccentColor"       -Value 0xFF000000 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $dwm -Name "ColorizationColor" -Value 0xC4000000 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideIcons" -Value 1 -Type DWord -Force -ErrorAction Stop
}

# ============================================================================
# 8. TASKBAR
# ============================================================================
Write-Step "Configuring taskbar"
$advanced = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$search   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"

Try-Step "Taskbar core settings (search/task view/badges/alignment)" {
    Set-ItemProperty -Path $search   -Name "SearchboxTaskbarMode" -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $advanced -Name "ShowTaskViewButton"   -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $advanced -Name "TaskbarMn"            -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $advanced -Name "MMTaskbarEnabled"     -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $advanced -Name "TaskbarBadges"        -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ForegroundFlashCount" -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $advanced -Name "TaskbarAl"            -Value 0 -Type DWord -Force -ErrorAction Stop
}

Try-Step "Widgets disabled via Group Policy" {
    $widgetsPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    if (-not (Test-Path $widgetsPolicy)) { New-Item -Path $widgetsPolicy -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $widgetsPolicy -Name "AllowNewsAndInterests" -Value 0 -Type DWord -Force -ErrorAction Stop
    # Also try the user-level toggle as belt-and-braces (often tamper-protected, ok if fails)
    Set-ItemProperty -Path $advanced -Name "TaskbarDa" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# 9. EDGE HARDENING
# ============================================================================
Write-Step "Hardening Edge"
Try-Step "Edge hardening policies set" {
    $edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    if (-not (Test-Path $edgePolicy)) { New-Item -Path $edgePolicy -Force -ErrorAction Stop | Out-Null }
    $settings = @{
        "BrowserSignin"                 = 0; "SyncDisabled"                  = 1
        "HideFirstRunExperience"        = 1; "PersonalizationReportingEnabled" = 0
        "DiagnosticData"                = 0; "AutofillCreditCardEnabled"     = 0
        "AutofillAddressEnabled"        = 0; "PasswordManagerEnabled"        = 0
        "PromotionalTabsEnabled"        = 0; "ShowRecommendationsEnabled"    = 0
        "EdgeShoppingAssistantEnabled"  = 0; "HubsSidebarEnabled"            = 0
    }
    foreach ($k in $settings.Keys) {
        Set-ItemProperty -Path $edgePolicy -Name $k -Value $settings[$k] -Type DWord -Force -ErrorAction Stop
    }
}

# ============================================================================
# 10. WINGET PACKAGE INSTALLS
# ============================================================================
Write-Step "Installing apps via winget"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Record-Fail "winget not found - install 'App Installer' from Microsoft Store and re-run"
} else {
    $packages = @(
        @{ Id = "astral-sh.uv";          Name = "uv (Python manager)" }
        @{ Id = "tailscale.tailscale";   Name = "Tailscale" }
        @{ Id = "OBSProject.OBSStudio";  Name = "OBS Studio" }
        @{ Id = "Git.Git";               Name = "Git" }
    )

    foreach ($pkg in $packages) {
        Write-Detail "Installing $($pkg.Name)..."
        try {
            $null = winget install --id $pkg.Id --source winget --silent --accept-package-agreements --accept-source-agreements 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0 -or $exitCode -eq -1978335189) {
                Record-Pass "Installed $($pkg.Name)"
            } else {
                Record-Fail "Install of $($pkg.Name) failed (exit code $exitCode)"
            }
        } catch {
            Record-Fail "Install of $($pkg.Name) threw exception: $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# 11. TIGHTVNC SERVER INSTALL (server only, no viewer)
# ============================================================================
Write-Step "Installing TightVNC server (server only, no viewer)"
$tightVncMsi = "$env:TEMP\tightvnc-server.msi"
Try-Step "TightVNC server installed with password" {
    $tightVncUrl = "https://www.tightvnc.com/download/2.8.87/tightvnc-2.8.87-gpl-setup-64bit.msi"
    Invoke-WebRequest -Uri $tightVncUrl -OutFile $tightVncMsi -UseBasicParsing -ErrorAction Stop
    $msiArgs = @(
        "/i", "`"$tightVncMsi`"", "/qn",
        "ADDLOCAL=Server",
        "SERVER_REGISTER_AS_SERVICE=1",
        "SERVER_ADD_FIREWALL_EXCEPTION=1",
        "SET_USEVNCAUTHENTICATION=1",
        "VALUE_OF_USEVNCAUTHENTICATION=1",
        "SET_PASSWORD=1",
        "VALUE_OF_PASSWORD=$TightVNCPassword"
    )
    $msiProc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru -ErrorAction Stop
    if ($msiProc.ExitCode -ne 0) { throw "MSI install returned exit code $($msiProc.ExitCode)" }
}
Remove-Item $tightVncMsi -ErrorAction SilentlyContinue

Write-Step "Verifying TightVNC password is set"
Try-Step "TightVNC password verified" -WarnOnFail {
    $vncPath = "HKLM:\SOFTWARE\TightVNC\Server"
    $tvn = "${env:ProgramFiles}\TightVNC\tvnserver.exe"

    $waited = 0
    while (-not (Test-Path $vncPath) -and $waited -lt 30) {
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if (-not (Test-Path $vncPath)) { throw "TightVNC registry key never appeared" }

    $passwordSet = $false
    try {
        $pwBytes = (Get-ItemProperty -Path $vncPath -Name "Password" -ErrorAction Stop).Password
        if ($pwBytes -and $pwBytes.Length -gt 0) { $passwordSet = $true }
    } catch {}

    if ($passwordSet) {
        Write-Detail "Password set by MSI install"
        return $true
    }

    if (-not (Test-Path $tvn)) { throw "tvnserver.exe not found and password isn't set" }

    Write-Detail "Password not set by MSI - falling back to CLI with retries"
    for ($i = 1; $i -le 5; $i++) {
        $svc = Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Running") {
            Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        & $tvn -controlservice -setvncpassword $TightVNCPassword 2>$null
        Start-Sleep -Seconds 2
        try {
            $pwBytes = (Get-ItemProperty -Path $vncPath -Name "Password" -ErrorAction Stop).Password
            if ($pwBytes -and $pwBytes.Length -gt 0) {
                Write-Detail "Password set on attempt $i"
                return $true
            }
        } catch {}
    }
    throw "Could not set TightVNC password after 5 retries"
}

# ============================================================================
# 12. CREATE C:\code DIRECTORY
# ============================================================================
Write-Step "Creating C:\code directory"
Try-Step "C:\code directory created" {
    New-Item -Path "C:\code" -ItemType Directory -Force -ErrorAction Stop | Out-Null
}

# ============================================================================
# 13. KIOSK HARDENING
# ============================================================================
Write-Step "Disabling lock screen and notifications"
Try-Step "Lock screen disabled" {
    $p = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
    if (-not (Test-Path $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $p -Name "NoLockScreen" -Value 1 -Type DWord -Force -ErrorAction Stop
}
Try-Step "Notifications disabled" {
    $pushNotif = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
    if (-not (Test-Path $pushNotif)) { New-Item -Path $pushNotif -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $pushNotif -Name "ToastEnabled" -Value 0 -Type DWord -Force -ErrorAction Stop
    $notifSettings = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    if (-not (Test-Path $notifSettings)) { New-Item -Path $notifSettings -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $notifSettings -Name "NOC_GLOBAL_SETTING_TOASTS_ENABLED" -Value 0 -Type DWord -Force -ErrorAction Stop
}
Try-Step "Windows tips/suggestions disabled" -WarnOnFail {
    $contentDelivery = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    foreach ($name in @("SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled",
                        "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled",
                        "SystemPaneSuggestionsEnabled", "SoftLandingEnabled",
                        "RotatingLockScreenEnabled", "RotatingLockScreenOverlayEnabled")) {
        Set-ItemProperty -Path $contentDelivery -Name $name -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }
    $cloudContent = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    if (-not (Test-Path $cloudContent)) { New-Item -Path $cloudContent -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $cloudContent -Name "DisableSoftLanding"             -Value 1 -Type DWord -Force -ErrorAction Stop
}

# ============================================================================
# 14. CORTANA + STORAGE SENSE
# ============================================================================
Write-Step "Disabling Cortana and Storage Sense"
Try-Step "Cortana disabled" {
    $cortanaPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    if (-not (Test-Path $cortanaPolicy)) { New-Item -Path $cortanaPolicy -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $cortanaPolicy -Name "AllowCortana"             -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $cortanaPolicy -Name "ConnectedSearchUseWeb"    -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $cortanaPolicy -Name "AllowSearchToUseLocation" -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $cortanaPolicy -Name "DisableWebSearch"         -Value 1 -Type DWord -Force -ErrorAction Stop
    $explorerPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
    if (-not (Test-Path $explorerPolicy)) { New-Item -Path $explorerPolicy -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $explorerPolicy -Name "BingSearchEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $explorerPolicy -Name "CortanaConsent"    -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}
Try-Step "Storage Sense disabled" {
    $storageSenseUser   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
    $storageSensePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense"
    if (-not (Test-Path $storageSenseUser))   { New-Item -Path $storageSenseUser   -Force -ErrorAction Stop | Out-Null }
    if (-not (Test-Path $storageSensePolicy)) { New-Item -Path $storageSensePolicy -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $storageSenseUser   -Name "01"                      -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $storageSensePolicy -Name "AllowStorageSenseGlobal" -Value 0 -Type DWord -Force -ErrorAction Stop
}

# ============================================================================
# 15. BULLETPROOFING - ALWAYS-ON REMOTE ACCESS
# ============================================================================
Write-Step "Bulletproofing (lock prevention + service reliability)"

Try-Step "Screensaver disabled" {
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveActive"    -Value "0" -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveTimeOut"   -Value "0" -Force -ErrorAction Stop
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaverIsSecure" -Value "0" -Force -ErrorAction Stop
    $ssPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop"
    if (-not (Test-Path $ssPolicy)) { New-Item -Path $ssPolicy -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $ssPolicy -Name "ScreenSaveActive" -Value "0" -Force -ErrorAction Stop
}
Try-Step "Win+L lock disabled" {
    $systemPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    if (-not (Test-Path $systemPolicy)) { New-Item -Path $systemPolicy -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $systemPolicy -Name "DisableLockWorkstation" -Value 1 -Type DWord -Force -ErrorAction Stop
}
Try-Step "Dynamic lock disabled" -WarnOnFail {
    $winLogonPolicy = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $winLogonPolicy -Name "EnableGoodbye" -Value 0 -Type DWord -Force -ErrorAction Stop
}
Try-Step "Account lockout disabled" {
    $netOutput = & net accounts /lockoutthreshold:0 2>&1
    if ($LASTEXITCODE -ne 0) { throw "net accounts failed: $netOutput" }
}
Try-Step "Update auto-reboot prevention enforced" {
    $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Set-ItemProperty -Path $auPath -Name "NoAutoRebootWithLoggedOnUsers"     -Value 1 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $auPath -Name "AlwaysAutoRebootAtScheduledTime"   -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}
Try-Step "Power buttons disabled (button/sleep/lid/critical battery)" {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BATTERY BATACTIONCRIT 0
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BATTERY BATACTIONCRIT 0
    powercfg /setactive SCHEME_CURRENT
    if ($LASTEXITCODE -ne 0) { throw "powercfg returned exit code $LASTEXITCODE" }
}

foreach ($svc in @("Tailscale", "tvnserver")) {
    Try-Step "Service '$svc' set to auto-start with restart-on-failure" -WarnOnFail {
        $service = $null
        $waited = 0
        while (-not $service -and $waited -lt 30) {
            $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $service) { Start-Sleep -Seconds 3; $waited += 3 }
        }
        if (-not $service) { throw "service '$svc' not found - configure manually" }
        Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop
        & sc.exe failure $svc reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe failure returned exit code $LASTEXITCODE" }
    }
}

# ============================================================================
# 16. DISABLE USB AUTORUN
# ============================================================================
Write-Step "Disabling USB autorun/autoplay"
Try-Step "USB autorun disabled" {
    $autoplay = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    if (-not (Test-Path $autoplay)) { New-Item -Path $autoplay -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $autoplay -Name "NoDriveTypeAutoRun" -Value 0xFF -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $autoplay -Name "NoAutorun"          -Value 1    -Type DWord -Force -ErrorAction Stop
}

# ============================================================================
# 17. TIME SYNC
# ============================================================================
Write-Step "Configuring Windows time service"
Try-Step "Time sync configured" {
    Start-Service w32time -ErrorAction SilentlyContinue
    Set-Service  w32time -StartupType Automatic -ErrorAction Stop
    & w32tm /config /manualpeerlist:"time.windows.com,0x1 pool.ntp.org,0x1" /syncfromflags:manual /update | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "w32tm /config returned exit code $LASTEXITCODE" }
    & w32tm /resync | Out-Null
}

# ============================================================================
# 18. CURSOR AUTO-HIDE (AutoHotkey)
# ============================================================================
Write-Step "Setting up cursor auto-hide"

Try-Step "AutoHotkey installed" -WarnOnFail {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "winget not available" }
    $null = winget install --id AutoHotkey.AutoHotkey --source winget --silent --accept-package-agreements --accept-source-agreements 2>&1
    Start-Sleep -Seconds 2
}

$ahkExeCandidates = @(
    "${env:ProgramFiles}\AutoHotkey\v2\AutoHotkey64.exe",
    "${env:ProgramFiles}\AutoHotkey\AutoHotkey64.exe",
    "${env:LOCALAPPDATA}\Programs\AutoHotkey\v2\AutoHotkey64.exe",
    "$env:USERPROFILE\AppData\Local\Programs\AutoHotkey\v2\AutoHotkey64.exe"
)
$ahkExe = $ahkExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

$ahkScript = @'
; Hide cursor after 3 seconds of inactivity. Show again on any mouse movement.
#Requires AutoHotkey v2.0
#SingleInstance Force

idleTimeout := 3000
hidden := false

SetTimer(CheckIdle, 500)

CheckIdle() {
    global hidden, idleTimeout
    if (A_TimeIdleMouse > idleTimeout && !hidden) {
        SystemCursor("Off")
        hidden := true
    } else if (A_TimeIdleMouse < 500 && hidden) {
        SystemCursor("On")
        hidden := false
    }
}

SystemCursor(cmd) {
    static cursors := Map(), handles := [32512, 32513, 32514, 32515, 32516, 32642, 32643,
                                          32644, 32645, 32646, 32648, 32649, 32650, 32651]
    if (cursors.Count = 0) {
        for h in handles {
            cursors[h] := DllCall("CopyImage", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", h, "Ptr"),
                                  "UInt", 2, "Int", 0, "Int", 0, "UInt", 0, "Ptr")
        }
    }
    if (cmd = "Off") {
        for h in handles {
            blank := DllCall("CreateCursor", "Ptr", 0, "Int", 0, "Int", 0,
                             "Int", 32, "Int", 32,
                             "Ptr", Buffer(128, 0xFF).Ptr,
                             "Ptr", Buffer(128, 0x00).Ptr, "Ptr")
            DllCall("SetSystemCursor", "Ptr", blank, "UInt", h)
        }
    } else {
        for h, original in cursors {
            copy := DllCall("CopyImage", "Ptr", original, "UInt", 2, "Int", 0, "Int", 0, "UInt", 0, "Ptr")
            DllCall("SetSystemCursor", "Ptr", copy, "UInt", h)
        }
    }
}
'@

$ahkPath = "C:\code\hide-cursor.ahk"
Try-Step "AHK script file written to $ahkPath" {
    # UTF-8 without BOM (AHK sometimes chokes on BOM)
    [System.IO.File]::WriteAllText($ahkPath, $ahkScript, [System.Text.UTF8Encoding]::new($false))
}

$hollyStartup = "C:\Users\holly\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
Try-Step "Cursor auto-hide startup shortcut created" -WarnOnFail {
    if (-not $ahkExe) { throw "AutoHotkey64.exe not found - install may have failed" }
    if (-not (Test-Path $hollyStartup)) { throw "holly's Startup folder not found - profile may not exist yet" }

    # Remove old broken .ahk file from previous script versions
    $oldDirectPath = "$hollyStartup\hide-cursor.ahk"
    if (Test-Path $oldDirectPath) { Remove-Item $oldDirectPath -Force -ErrorAction SilentlyContinue }

    $shortcutPath = "$hollyStartup\hide-cursor.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($shortcutPath)
    $sc.TargetPath = $ahkExe
    $sc.Arguments = "`"$ahkPath`""
    $sc.WorkingDirectory = "C:\code"
    $sc.WindowStyle = 7
    $sc.Description = "Auto-hide cursor when idle"
    $sc.Save()
    Write-Detail "Shortcut points at: $ahkExe"
}

# ============================================================================
# 19. TAILSCALE AUTO-CONNECT (if auth key provided)
# ============================================================================
if ($TailscaleAuthKey) {
    Write-Step "Connecting Tailscale with auth key"
    Try-Step "Tailscale connected via auth key" -WarnOnFail {
        $tailscale = "${env:ProgramFiles}\Tailscale\tailscale.exe"
        if (-not (Test-Path $tailscale)) { throw "Tailscale not installed - sign in manually after reboot" }
        & $tailscale up --authkey=$TailscaleAuthKey --unattended --hostname=$NewHostname --accept-routes
        if ($LASTEXITCODE -ne 0) { throw "tailscale up returned exit code $LASTEXITCODE" }
    }
} else {
    Write-Step "Skipping Tailscale auto-connect (no auth key)"
    Record-Warn "Tailscale auth key not set - sign in manually: tailscale up --unattended --hostname=$NewHostname"
}

# ============================================================================
# 20. FINAL: DISABLE WIFI + BLUETOOTH
# ============================================================================
Write-Step "Disabling Wi-Fi and Bluetooth"
$wifiAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
    $_.PhysicalMediaType -like "*802.11*" -or $_.Name -like "*Wi-Fi*" -or $_.Name -like "*Wireless*"
})
$wifiDisabled = 0
foreach ($adapter in $wifiAdapters) {
    try {
        Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction Stop
        $wifiDisabled++
        Write-Detail "disabled wifi: $($adapter.Name)"
    } catch {}
}
if ($wifiAdapters.Count -eq 0) {
    Record-Warn "No Wi-Fi adapters found (already disabled from a previous run?)"
} elseif ($wifiDisabled -eq $wifiAdapters.Count) {
    Record-Pass "Wi-Fi disabled ($wifiDisabled adapter(s))"
} else {
    Record-Fail "Wi-Fi disable: only $wifiDisabled of $($wifiAdapters.Count) adapters disabled"
}

$btDevices = @(Get-PnpDevice -Class "Bluetooth" -ErrorAction SilentlyContinue)
$btDisabled = 0
foreach ($dev in $btDevices) {
    try {
        Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false -ErrorAction Stop
        $btDisabled++
        Write-Detail "disabled bt: $($dev.FriendlyName)"
    } catch {}
}
if ($btDevices.Count -eq 0) {
    Record-Warn "No Bluetooth devices found (already disabled?)"
} elseif ($btDisabled -ge 1) {
    Record-Pass "Bluetooth disabled ($btDisabled of $($btDevices.Count) devices)"
} else {
    Record-Fail "Bluetooth disable failed (0 of $($btDevices.Count) devices disabled)"
}

# ============================================================================
# RESTART EXPLORER
# ============================================================================
Write-Step "Restarting Explorer to apply UI changes"
try {
    Stop-Process -Name explorer -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
} catch {}

# ============================================================================
# FINAL SUMMARY + STATUS FILE
# ============================================================================
$Results.Finished = Get-Date
$duration = ($Results.Finished - $Results.Started).TotalMinutes
$passedCount = $Results.Passed.Count
$warnedCount = $Results.Warned.Count
$failedCount = $Results.Failed.Count

if ($failedCount -eq 0 -and $warnedCount -eq 0) {
    $status = "READY"; $statusColor = "Green"
} elseif ($failedCount -eq 0) {
    $status = "READY-WITH-WARNINGS"; $statusColor = "Yellow"
} else {
    $status = "INCOMPLETE"; $statusColor = "Red"
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host " Setup summary for $NewHostname" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Passed:    $passedCount" -ForegroundColor Green
Write-Host "  Warnings:  $warnedCount" -ForegroundColor Yellow
Write-Host "  Failed:    $failedCount" -ForegroundColor Red
Write-Host "  Duration:  $([math]::Round($duration, 1)) min"
Write-Host ""

if ($warnedCount -gt 0) {
    Write-Host "  Warnings:" -ForegroundColor Yellow
    foreach ($w in $Results.Warned) { Write-Host "    - $w" -ForegroundColor Yellow }
    Write-Host ""
}
if ($failedCount -gt 0) {
    Write-Host "  Failures:" -ForegroundColor Red
    foreach ($f in $Results.Failed) { Write-Host "    - $f" -ForegroundColor Red }
    Write-Host ""
}

Write-Host "  Status: $status" -ForegroundColor $statusColor
Write-Host ""

# Write a JSON status file - useful for fleet-wide health audit over Tailscale.
# You can later run something like:
#   Invoke-Command -ComputerName HOLLY-001,HOLLY-002,... -ScriptBlock { Get-Content C:\code\setup-status.json }
$statusJson = @{
    hostname     = $NewHostname
    status       = $status
    passed       = $passedCount
    warned       = $warnedCount
    failed       = $failedCount
    warnings     = @($Results.Warned)
    failures     = @($Results.Failed)
    started      = $Results.Started.ToString("o")
    finished     = $Results.Finished.ToString("o")
    duration_min = [math]::Round($duration, 1)
} | ConvertTo-Json -Depth 5

try {
    if (-not (Test-Path "C:\code")) { New-Item -Path "C:\code" -ItemType Directory -Force | Out-Null }
    $statusJson | Out-File -FilePath "C:\code\setup-status.json" -Encoding UTF8 -Force
    Write-Host "  Status file: C:\code\setup-status.json" -ForegroundColor DarkGray
} catch {
    Write-Host "  Could not write status file: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Manual steps remaining:" -ForegroundColor Cyan
Write-Host "  1. Reboot now (hostname change requires it)"
Write-Host "  2. After reboot, run Windows Update manually until clean"
Write-Host "  3. Clone your repo into C:\code"
if (-not $TailscaleAuthKey) {
    Write-Host "  4. Sign in to Tailscale: tailscale up --unattended --hostname=$NewHostname"
}
Write-Host "  5. Open OBS once and pick 'I will only be using the virtual camera'"
Write-Host "  6. Open Device Manager and disable built-in audio/camera (keep USB)"
Write-Host "  7. Label the PC with $NewHostname on the bottom"
Write-Host ""

Stop-Transcript | Out-Null

$reboot = Read-Host "Reboot now? (y/n)"
if ($reboot -eq "y") { Restart-Computer -Force }