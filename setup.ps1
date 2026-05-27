<#
.SYNOPSIS
    Automated setup script for Holly NUC PCs.

.DESCRIPTION
    Runs after Windows OOBE is complete. Configures the machine to match
    the Holly-spec build: debloated, locked down, with required apps installed.

.USAGE
    1. Complete Windows OOBE manually (say no to everything, don't join wifi).
    2. Plug in ethernet.
    3. Open PowerShell AS ADMINISTRATOR.
    4. If script is blocked: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    5. Run: .\Setup-HollyPC.ps1 -PCNumber 001

.PARAMETER PCNumber
    Three-digit number for this PC, used in hostname HOLLY-NNN. e.g. "001", "002"
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d{3}$')]
    [string]$PCNumber
)

# ============================================================================
# CONFIG - edit these before running on the first PC
# ============================================================================
$HollyPassword     = "holly"   # Password for the Holly user
$TightVNCPassword  = "holly"   # VNC connection password (max 8 chars for legacy clients)
$NewHostname       = "HOLLY-$PCNumber"

# ----- Tailscale -----
#
# Tailscale uses TAGGED DEVICES for fleet PCs - the device is owned by a tag
# (like "tag:holly-pc"), not by a human user. This means:
#   - No GitHub account is needed on the PC
#   - Devices don't expire (user-owned devices expire every 180 days; tagged ones don't)
#   - Devices survive even if the admin who onboarded them leaves the org
#   - ACL rules control what tagged devices can reach (e.g. just AWS, just admin VNC)
#
# ONE-TIME TAILNET SETUP (done once by a tailnet admin, not per PC):
#
#   1. Go to https://login.tailscale.com/admin/acls
#   2. Edit the ACL policy file. Add a tagOwners section if not already there:
#
#         "tagOwners": {
#           "tag:holly-pc": ["your-email@company.com", "boss-email@company.com"]
#         }
#
#      This restricts who is allowed to create devices with this tag.
#
#   3. Add ACL rules controlling what Holly PCs can access. Example - only allow
#      Holly PCs to reach your AWS backend, and only admins to VNC into them:
#
#         "acls": [
#           { "action": "accept", "src": ["tag:holly-pc"], "dst": ["your-aws-host:443"] },
#           { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:holly-pc:*"] }
#         ]
#
#      Adjust to match your actual hosts. Tighter = better.
#
# PER-BATCH AUTH KEY (generate one key, reuse for all PCs in a batch):
#
#   1. Go to https://login.tailscale.com/admin/settings/keys
#   2. Click "Generate auth key"
#   3. Set these options:
#        - Reusable:        YES   (so you can use it for every PC, not just one)
#        - Ephemeral:       NO    (you want PCs to persist in console even when offline)
#        - Pre-approved:    YES   (devices appear immediately without admin approval)
#        - Tags:            tag:holly-pc
#        - Expiration:      up to 90 days (only affects creating NEW devices - existing
#                                          PCs stay connected indefinitely after onboarding)
#   4. Copy the key into the $TailscaleAuthKey variable below.
#
# WHO CREATED WHICH PC (audit trail):
#   Even though the device is tag-owned, Tailscale logs which admin's auth key
#   onboarded each device. See Settings -> Logs in the admin console.
#
# Leave $TailscaleAuthKey empty to install Tailscale but sign in manually later.
#
$TailscaleAuthKey  = ""                            # e.g. "tskey-auth-kXXXXXXXXXX-XXXXXXXXXX"

# ============================================================================
# PRE-FLIGHT
# ============================================================================
$ErrorActionPreference = "Continue"   # don't bail on a single failure - log and move on

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Must run as Administrator." -ForegroundColor Red
    exit 1
}

if ($HollyPassword -eq "CHANGE_ME_BEFORE_RUNNING") {
    Write-Host "ERROR: Edit the script and set HollyPassword and TightVNCPassword first." -ForegroundColor Red
    exit 1
}

function Write-Step($msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [WARN] $msg" -ForegroundColor Yellow }

# Start a transcript so we have a log if something goes sideways
Start-Transcript -Path "$env:USERPROFILE\Desktop\Setup-$NewHostname.log" -Append | Out-Null

Write-Host "`n=== Setting up $NewHostname ===" -ForegroundColor Magenta

# ============================================================================
# 1. RENAME PC
# ============================================================================
Write-Step "Renaming computer to $NewHostname"
try {
    Rename-Computer -NewName $NewHostname -Force -ErrorAction Stop
    Write-OK "Renamed (takes effect on reboot)"
} catch { Write-Warn "Rename failed: $_" }

# ============================================================================
# 2. CONFIGURE AUTO-LOGIN FOR HOLLY
# ============================================================================
# Holly account is created during OOBE. This step just makes Windows boot
# straight to the desktop without ever showing the login prompt.
Write-Step "Configuring auto-login for Holly"

# Sanity check - confirm the holly user actually exists from OOBE
if (-not (Get-LocalUser -Name "holly" -ErrorAction SilentlyContinue)) {
    Write-Warn "holly user not found! Did you create it during OOBE? Auto-login will fail."
    Write-Warn "Continuing with the rest of setup - you can fix this later."
} else {
    # The password is stored in the registry (this is how Windows auto-login works - no way around it)
    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $winlogon -Name "AutoAdminLogon"    -Value "1"
    Set-ItemProperty -Path $winlogon -Name "DefaultUserName"   -Value "holly"
    Set-ItemProperty -Path $winlogon -Name "DefaultPassword"   -Value $HollyPassword
    Set-ItemProperty -Path $winlogon -Name "DefaultDomainName" -Value $env:COMPUTERNAME

    # Disable "press Ctrl+Alt+Del to sign in" prompt if it's ever enabled
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableCAD" -Value 1 -Type DWord -Force
    Write-OK "Auto-login set for holly"
}

# ============================================================================
# 3. UNINSTALL BLOATWARE
# ============================================================================
Write-Step "Uninstalling Microsoft Store bloatware (AppX packages)"

# Apps to KEEP - everything else gets nuked
$keep = @(
    "*Microsoft.WindowsStore*"        # store itself (needed for some app updates)
    "*Microsoft.DesktopAppInstaller*" # winget
    "*Microsoft.WindowsNotepad*"      # you asked to keep Notepad
    "*Microsoft.WindowsTerminal*"     # useful for you, harmless for Holly
    "*Microsoft.VCLibs*"              # runtime dependencies
    "*Microsoft.NET*"                 # runtime dependencies
    "*Microsoft.UI.Xaml*"             # runtime dependencies
    "*Microsoft.WindowsCalculator*"   # harmless, sometimes useful
    "*Microsoft.Paint*"               # harmless
    "*Microsoft.ScreenSketch*"        # Snipping Tool - useful
    "*Microsoft.SecHealthUI*"         # Defender UI - don't break this
    "*Microsoft.HEIFImageExtension*"  # codec
    "*Microsoft.HEVCVideoExtension*"  # codec
    "*Microsoft.VP9VideoExtensions*"  # codec
    "*Microsoft.WebMediaExtensions*"  # codec
    "*Microsoft.WebpImageExtension*"  # codec
    "*Microsoft.RawImageExtension*"   # codec
    "*Microsoft.AV1VideoExtension*"   # codec
    "*Microsoft.StorePurchaseApp*"    # needed for store to work
    "*Microsoft.Services.Store.Engagement*"  # needed for store
    "*Microsoft.UI.Xaml.CBS*"         # system UI
    "*MicrosoftWindows.Client.CBS*"   # system UI
    "*MicrosoftWindows.Client.WebExperience*"  # leaving this kills explorer in some builds - safer to keep
    "*Windows.PrintDialog*"           # printing
    "*Microsoft.WindowsFeedbackHub*"  # safer to keep, harmless
    "*Microsoft.LockApp*"             # system
    "*Microsoft.AAD.BrokerPlugin*"    # auth - removing breaks login on some builds
    "*Microsoft.Windows.Cortana*"     # safer to keep stub - removing can break Search
    "*Windows.CBSPreview*"
    "*Microsoft.MicrosoftEdgeDevToolsClient*"
    "*Microsoft.Win32WebViewHost*"
    "*Microsoft.Windows.AssignedAccessLockApp*"
    "*Microsoft.Windows.CapturePicker*"
    "*Microsoft.Windows.CloudExperienceHost*"
    "*Microsoft.Windows.ContentDeliveryManager*"
    "*Microsoft.Windows.OOBENetworkConnectionFlow*"
    "*Microsoft.Windows.OOBENetworkCaptivePortal*"
    "*Microsoft.Windows.ParentalControls*"
    "*Microsoft.Windows.PeopleExperienceHost*"
    "*Microsoft.Windows.PinningConfirmationDialog*"
    "*Microsoft.Windows.SecureAssessmentBrowser*"
    "*Microsoft.Windows.ShellExperienceHost*"
    "*Microsoft.Windows.StartMenuExperienceHost*"
    "*Microsoft.Windows.XGpuEjectDialog*"
    "*Microsoft.XboxGameCallableUI*"   # KEEP stub - removing the runtime kills some apps
    "*Microsoft.AccountsControl*"
    "*Microsoft.AsyncTextService*"
    "*Microsoft.BioEnrollment*"
    "*Microsoft.CredDialogHost*"
    "*Microsoft.ECApp*"
    "*Microsoft.LanguageExperiencePack*"
    "*Microsoft.WindowsAppRuntime*"
    "*Microsoft.WinAppRuntime*"
    "*NVIDIA*"   # GPU drivers
    "*AMD*"      # you asked to keep AMD/CPU software
    "*Realtek*"  # audio drivers (even though you're muting them, keep the driver)
    "*Intel*"    # chipset drivers
)

# Get every appx package, exclude the keep list, remove the rest
$allApps = Get-AppxPackage -AllUsers
$toRemove = $allApps | Where-Object {
    $name = $_.Name
    -not ($keep | Where-Object { $name -like $_ })
}

Write-Host "    Removing $($toRemove.Count) app packages..."
foreach ($app in $toRemove) {
    try {
        Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
        Write-Host "      removed: $($app.Name)" -ForegroundColor DarkGray
    } catch {
        Write-Host "      skip:    $($app.Name)" -ForegroundColor DarkGray
    }
}

# Also remove provisioned packages (these are the ones that re-install for new users)
Write-Step "Removing provisioned app packages (stops them coming back for new users)"
$provisioned = Get-AppxProvisionedPackage -Online
foreach ($app in $provisioned) {
    $displayName = $app.DisplayName
    if (-not ($keep | Where-Object { $displayName -like $_.Trim('*') -or "*$displayName*" -like $_ })) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $app.PackageName -ErrorAction Stop | Out-Null
        } catch { }
    }
}
Write-OK "AppX cleanup done"

# ============================================================================
# 4. UNINSTALL ONEDRIVE
# ============================================================================
Write-Step "Removing OneDrive"
# Kill any running instances first
Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$oneDriveSetup = @(
    "$env:SystemRoot\System32\OneDriveSetup.exe",
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($oneDriveSetup) {
    Start-Process $oneDriveSetup -ArgumentList "/uninstall" -Wait -NoNewWindow
    Write-OK "OneDrive uninstalled"
} else {
    Write-Warn "OneDriveSetup.exe not found - may already be removed"
}

# Clean up any leftover folders + scheduled tasks + startup entries
Remove-Item -Path "$env:USERPROFILE\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:PROGRAMDATA\Microsoft OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName "OneDrive*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
# Hide OneDrive from File Explorer navigation pane
# Use HKLM:\SOFTWARE\Classes\ instead of HKCR: because the HKCR PSDrive isn't
# always available in PowerShell sessions (cause of the -Type error in earlier runs).
$oneDriveClsid = "HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
if (Test-Path $oneDriveClsid) {
    Set-ItemProperty -Path $oneDriveClsid -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Force -ErrorAction SilentlyContinue
}
# Also do the 32-bit variant for safety on 64-bit Windows
$oneDriveClsid32 = "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
if (Test-Path $oneDriveClsid32) {
    Set-ItemProperty -Path $oneDriveClsid32 -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# 5. WINDOWS UPDATE - DISABLE AUTO, SET ACTIVE HOURS
# ============================================================================
Write-Step "Configuring Windows Update (no auto-restart, active hours 06:00-22:00)"

$wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$auPath = "$wuPath\AU"
New-Item -Path $wuPath -Force | Out-Null
New-Item -Path $auPath -Force | Out-Null

# AUOptions = 2 means "notify before download" - effectively manual updates
Set-ItemProperty -Path $auPath -Name "AUOptions"        -Value 2 -Type DWord -Force
Set-ItemProperty -Path $auPath -Name "NoAutoUpdate"     -Value 0 -Type DWord -Force   # 0 = enabled but controlled by AUOptions
Set-ItemProperty -Path $auPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force

# Active hours (6 AM to 10 PM = 6 to 22)
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "ActiveHoursStart" -Value 6  -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "ActiveHoursEnd"   -Value 22 -Type DWord -Force
Write-OK "Update policy set"

# ============================================================================
# 6. POWER - NEVER SLEEP, NEVER TURN SCREEN OFF
# ============================================================================
Write-Step "Setting power plan to never sleep / never screen off"
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change disk-timeout-ac    0
powercfg /change disk-timeout-dc    0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /hibernate off
Write-OK "Power configured"


# ============================================================================
# 8. APPEARANCE - DARK MODE, SOLID BG, HIDE DESKTOP ICONS
# ============================================================================
Write-Step "Dark mode + solid black background + hide desktop icons"
$personalize = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
if (-not (Test-Path $personalize)) { New-Item -Path $personalize -Force | Out-Null }
Set-ItemProperty -Path $personalize -Name "AppsUseLightTheme"    -Value 0 -Type DWord -Force
Set-ItemProperty -Path $personalize -Name "SystemUsesLightTheme" -Value 0 -Type DWord -Force

# Solid colour background (black). Setting Wallpaper to empty + colour via Colors\Background
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop"      -Name "Wallpaper" -Value "" -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Colors"       -Name "Background" -Value "0 0 0" -Force
# Also set via the modern path
$dwm = "HKCU:\SOFTWARE\Microsoft\Windows\DWM"
if (-not (Test-Path $dwm)) { New-Item -Path $dwm -Force | Out-Null }
Set-ItemProperty -Path $dwm -Name "AccentColor"        -Value 0xFF000000 -Type DWord -Force
Set-ItemProperty -Path $dwm -Name "ColorizationColor"  -Value 0xC4000000 -Type DWord -Force

# Hide all desktop icons
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideIcons" -Value 1 -Type DWord -Force
Write-OK "Appearance set"

# ============================================================================
# 9. TASKBAR - HIDE WIDGETS, TASK VIEW, SEARCH, BADGES; SINGLE DISPLAY ONLY
# ============================================================================
Write-Step "Configuring taskbar"
$advanced = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$search   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"

# Search bar off (0=hidden, 1=icon only, 2=box, 3=icon+label)
Set-ItemProperty -Path $search   -Name "SearchboxTaskbarMode" -Value 0 -Type DWord -Force
# Task view button off
Set-ItemProperty -Path $advanced -Name "ShowTaskViewButton"   -Value 0 -Type DWord -Force
# Widgets off (Win11) - using Group Policy at HKLM because HKCU TaskbarDa
# is protected by Windows 11 registry tamper protection and silently fails.
$widgetsPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
if (-not (Test-Path $widgetsPolicy)) { New-Item -Path $widgetsPolicy -Force | Out-Null }
Set-ItemProperty -Path $widgetsPolicy -Name "AllowNewsAndInterests" -Value 0 -Type DWord -Force
# Also try the user-level toggle as belt-and-braces (may or may not work depending on Windows build)
Set-ItemProperty -Path $advanced -Name "TaskbarDa" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
# Chat / Teams button off
Set-ItemProperty -Path $advanced -Name "TaskbarMn"            -Value 0 -Type DWord -Force
# Taskbar only on primary display (0=only main)
Set-ItemProperty -Path $advanced -Name "MMTaskbarEnabled"     -Value 0 -Type DWord -Force
# Badges (notification dots) off
Set-ItemProperty -Path $advanced -Name "TaskbarBadges"        -Value 0 -Type DWord -Force
# No flashing taskbar button when an app wants attention
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ForegroundFlashCount" -Value 0 -Type DWord -Force
# Taskbar alignment left (instead of centred Win11 default - tidier with fewer icons)
Set-ItemProperty -Path $advanced -Name "TaskbarAl"            -Value 0 -Type DWord -Force
Write-OK "Taskbar configured"

# ============================================================================
# 10. EDGE - LOCK DOWN
# ============================================================================
Write-Step "Hardening Edge (no signin, no sync, no first-run experience)"
$edgePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (-not (Test-Path $edgePolicy)) { New-Item -Path $edgePolicy -Force | Out-Null }

Set-ItemProperty -Path $edgePolicy -Name "BrowserSignin"                 -Value 0 -Type DWord -Force  # 0 = signin disabled
Set-ItemProperty -Path $edgePolicy -Name "SyncDisabled"                  -Value 1 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "HideFirstRunExperience"        -Value 1 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "PersonalizationReportingEnabled" -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "DiagnosticData"                -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "AutofillCreditCardEnabled"     -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "AutofillAddressEnabled"        -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "PasswordManagerEnabled"        -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "PromotionalTabsEnabled"        -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "ShowRecommendationsEnabled"    -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "EdgeShoppingAssistantEnabled"  -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgePolicy -Name "HubsSidebarEnabled"            -Value 0 -Type DWord -Force
Write-OK "Edge locked down"

# ============================================================================
# 11. WINGET - INSTALL APPS
# ============================================================================
Write-Step "Installing apps via winget"

# Make sure winget is available
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Warn "winget not found! You may need to install 'App Installer' from the Microsoft Store first."
    Write-Warn "Skipping app installation."
} else {
    $packages = @(
        @{ Id = "astral-sh.uv";          Name = "uv (Python manager)" }
        @{ Id = "tailscale.tailscale";   Name = "Tailscale" }
        @{ Id = "OBSProject.OBSStudio";  Name = "OBS Studio" }
        @{ Id = "Git.Git";               Name = "Git" }
    )

    # Track which installs failed so we can report at the end
    $failedInstalls = @()

    foreach ($pkg in $packages) {
        Write-Host "    Installing $($pkg.Name)..."
        # Drop --scope machine: some packages only support user-scope and silently
        # reject machine-scope. Letting winget pick the right scope is more reliable.
        $output = winget install --id $pkg.Id --source winget --silent --accept-package-agreements --accept-source-agreements 2>&1
        $exitCode = $LASTEXITCODE

        # winget returns:
        #   0          = success
        #   -1978335189 (0x8A150011) = already installed (also fine)
        # anything else = something went wrong
        if ($exitCode -eq 0 -or $exitCode -eq -1978335189) {
            Write-Host "      [OK]   $($pkg.Name)" -ForegroundColor Green
        } else {
            Write-Host "      [FAIL] $($pkg.Name) (exit code $exitCode)" -ForegroundColor Red
            $failedInstalls += $pkg.Name
        }
    }

    if ($failedInstalls.Count -eq 0) {
        Write-OK "All winget installs succeeded"
    } else {
        Write-Warn "These packages failed to install: $($failedInstalls -join ', ')"
        Write-Warn "You will need to install them manually with: winget install --source winget --id <PackageId>"
    }

    # TightVNC needs special handling - we want SERVER ONLY, not the viewer.
    # winget's TightVNC package installs both by default, so we download the MSI
    # directly and pass ADDLOCAL=Server to limit it to server-only.
    Write-Step "Installing TightVNC server (server only, no viewer)"
    $tightVncUrl = "https://www.tightvnc.com/download/2.8.87/tightvnc-2.8.87-gpl-setup-64bit.msi"
    $tightVncMsi = "$env:TEMP\tightvnc-server.msi"
    try {
        Invoke-WebRequest -Uri $tightVncUrl -OutFile $tightVncMsi -UseBasicParsing
        # ADDLOCAL=Server installs only the server component (no viewer)
        # SET_USEVNCAUTHENTICATION + VALUE_OF_USEVNCAUTHENTICATION enables password auth
        # SET_PASSWORD + VALUE_OF_PASSWORD sets the password during install (more reliable than tvnserver CLI later)
        $msiArgs = @(
            "/i", "`"$tightVncMsi`"",
            "/qn",
            "ADDLOCAL=Server",
            "SERVER_REGISTER_AS_SERVICE=1",
            "SERVER_ADD_FIREWALL_EXCEPTION=1",
            "SET_USEVNCAUTHENTICATION=1",
            "VALUE_OF_USEVNCAUTHENTICATION=1",
            "SET_PASSWORD=1",
            "VALUE_OF_PASSWORD=$TightVNCPassword"
        )
        $msiProc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
        if ($msiProc.ExitCode -eq 0) {
            Write-OK "TightVNC server installed with password (viewer skipped)"
        } else {
            Write-Warn "TightVNC MSI install returned exit code $($msiProc.ExitCode)"
        }
    } catch {
        Write-Warn "TightVNC download/install failed: $_"
        Write-Warn "Fallback: installing via winget (will include viewer)"
        winget install --id GlavSoft.TightVNC --source winget --silent --accept-package-agreements --accept-source-agreements
    } finally {
        Remove-Item $tightVncMsi -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# 12. VERIFY TIGHTVNC PASSWORD IS SET (with retry)
# ============================================================================
# Password is set during MSI install (more reliable than CLI), but verify it stuck.
# If for any reason the install didn't take, fall back to the CLI approach with retries.
Write-Step "Verifying TightVNC password is set"

$tvn = "${env:ProgramFiles}\TightVNC\tvnserver.exe"
$vncPath = "HKLM:\SOFTWARE\TightVNC\Server"

# Wait up to 30 seconds for the registry key to appear (post-install timing)
$waited = 0
while (-not (Test-Path $vncPath) -and $waited -lt 30) {
    Start-Sleep -Seconds 2
    $waited += 2
}

if (-not (Test-Path $vncPath)) {
    Write-Warn "TightVNC registry key never appeared - service may not be installed correctly"
} elseif (-not (Test-Path $tvn)) {
    Write-Warn "tvnserver.exe not found - set VNC password manually via system tray"
} else {
    # Check if the Password value exists in the registry (set during MSI install).
    # If empty/missing, fall back to CLI approach with retry-until-it-works.
    $passwordSet = $false
    try {
        $pwBytes = (Get-ItemProperty -Path $vncPath -Name "Password" -ErrorAction Stop).Password
        if ($pwBytes -and $pwBytes.Length -gt 0) { $passwordSet = $true }
    } catch { $passwordSet = $false }

    if ($passwordSet) {
        Write-OK "TightVNC password already set by MSI install"
    } else {
        Write-Host "    Password not yet set, setting via CLI with retries..." -ForegroundColor DarkGray
        $maxRetries = 5
        for ($i = 1; $i -le $maxRetries; $i++) {
            # Make sure the service is running before we try to talk to it
            $svc = Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne "Running") {
                Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
            & $tvn -controlservice -setvncpassword $TightVNCPassword 2>$null
            Start-Sleep -Seconds 2

            # Verify it actually took
            try {
                $pwBytes = (Get-ItemProperty -Path $vncPath -Name "Password" -ErrorAction Stop).Password
                if ($pwBytes -and $pwBytes.Length -gt 0) {
                    Write-OK "TightVNC password set (attempt $i)"
                    $passwordSet = $true
                    break
                }
            } catch {}
            Write-Host "      attempt $i failed, retrying..." -ForegroundColor DarkGray
        }
        if (-not $passwordSet) {
            Write-Warn "Could not set TightVNC password automatically - set manually via system tray"
        }
    }
}

# ============================================================================
# 13. CREATE C:\code DIRECTORY
# ============================================================================
Write-Step "Creating C:\code directory"
New-Item -Path "C:\code" -ItemType Directory -Force | Out-Null
Write-OK "C:\code ready (clone your repo here manually)"

# ============================================================================
# 14. KIOSK HARDENING - LOCK SCREEN, NOTIFICATIONS, FOCUS ASSIST
# ============================================================================
Write-Step "Disabling lock screen and all notifications (kiosk mode)"

# Never show the lock screen
$personalization = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
if (-not (Test-Path $personalization)) { New-Item -Path $personalization -Force | Out-Null }
Set-ItemProperty -Path $personalization -Name "NoLockScreen" -Value 1 -Type DWord -Force

# Disable all toast notifications system-wide
$pushNotif = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
if (-not (Test-Path $pushNotif)) { New-Item -Path $pushNotif -Force | Out-Null }
Set-ItemProperty -Path $pushNotif -Name "ToastEnabled" -Value 0 -Type DWord -Force

# Force "Do Not Disturb" / Focus mode permanently on (Win11)
$notifSettings = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
if (-not (Test-Path $notifSettings)) { New-Item -Path $notifSettings -Force | Out-Null }
Set-ItemProperty -Path $notifSettings -Name "NOC_GLOBAL_SETTING_TOASTS_ENABLED" -Value 0 -Type DWord -Force

# Disable tips, tricks, suggestions, the "get even more out of Windows" nags
$contentDelivery = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
foreach ($name in @("SubscribedContent-338388Enabled", "SubscribedContent-338389Enabled",
                    "SubscribedContent-353694Enabled", "SubscribedContent-353696Enabled",
                    "SystemPaneSuggestionsEnabled", "SoftLandingEnabled",
                    "RotatingLockScreenEnabled", "RotatingLockScreenOverlayEnabled")) {
    Set-ItemProperty -Path $contentDelivery -Name $name -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}

# Disable Windows Tips / "Get suggestions" - that blue notification that pops up out of nowhere
$cloudContent = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
if (-not (Test-Path $cloudContent)) { New-Item -Path $cloudContent -Force | Out-Null }
Set-ItemProperty -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $cloudContent -Name "DisableSoftLanding"             -Value 1 -Type DWord -Force
Write-OK "Notifications and lock screen disabled"

# ============================================================================
# 15. DISABLE CORTANA + STORAGE SENSE
# ============================================================================
# Cortana adds outbound traffic and Start menu latency - not useful for kiosks.
# Storage Sense can auto-delete files when disk is low - we don't want surprises.
Write-Step "Disabling Cortana and Storage Sense"

# --- Disable Cortana ---
$cortanaPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
if (-not (Test-Path $cortanaPolicy)) { New-Item -Path $cortanaPolicy -Force | Out-Null }
Set-ItemProperty -Path $cortanaPolicy -Name "AllowCortana"               -Value 0 -Type DWord -Force
Set-ItemProperty -Path $cortanaPolicy -Name "ConnectedSearchUseWeb"      -Value 0 -Type DWord -Force
Set-ItemProperty -Path $cortanaPolicy -Name "AllowSearchToUseLocation"   -Value 0 -Type DWord -Force
Set-ItemProperty -Path $cortanaPolicy -Name "DisableWebSearch"           -Value 1 -Type DWord -Force
# Stop the search box from also searching the web from the Start menu
$explorerPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
if (-not (Test-Path $explorerPolicy)) { New-Item -Path $explorerPolicy -Force | Out-Null }
Set-ItemProperty -Path $explorerPolicy -Name "BingSearchEnabled"         -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $explorerPolicy -Name "CortanaConsent"            -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

# --- Disable Storage Sense ---
# Storage Sense lives under HKCU per-user. Setting AllowStorageSenseGlobal to 0 disables it.
$storageSenseUser   = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
$storageSensePolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense"
if (-not (Test-Path $storageSenseUser))   { New-Item -Path $storageSenseUser   -Force | Out-Null }
if (-not (Test-Path $storageSensePolicy)) { New-Item -Path $storageSensePolicy -Force | Out-Null }
Set-ItemProperty -Path $storageSenseUser   -Name "01"                       -Value 0 -Type DWord -Force  # master switch off
Set-ItemProperty -Path $storageSensePolicy -Name "AllowStorageSenseGlobal"  -Value 0 -Type DWord -Force  # enforce at machine level
Write-OK "Cortana and Storage Sense disabled"

# ============================================================================
# 16. BULLETPROOFING - GUARANTEE ALWAYS-ON REMOTE ACCESS
# ============================================================================
# Belt-and-braces measures to ensure the PC stays reachable via Tailscale + VNC
# no matter what. Each block here closes a different lockout escape route.
Write-Step "Bulletproofing remote access (lock prevention + service reliability)"

# --- 16a. Disable screensaver completely ---
# Even with sleep off, a screensaver can engage and (depending on policy) lock the PC.
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveActive"  -Value "0" -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveTimeOut" -Value "0" -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaverIsSecure" -Value "0" -Force
# Also enforce via Group Policy in case a domain policy ever tries to set one
$ssPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop"
if (-not (Test-Path $ssPolicy)) { New-Item -Path $ssPolicy -Force | Out-Null }
Set-ItemProperty -Path $ssPolicy -Name "ScreenSaveActive" -Value "0" -Force

# --- 16b. Disable Win+L and the "Lock" option in the user menu ---
# Stops accidental or fat-fingered lock via VNC. Also removes Lock from the Ctrl+Alt+Del screen.
$systemPolicy = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
if (-not (Test-Path $systemPolicy)) { New-Item -Path $systemPolicy -Force | Out-Null }
Set-ItemProperty -Path $systemPolicy -Name "DisableLockWorkstation" -Value 1 -Type DWord -Force

# --- 16c. Disable dynamic lock (Bluetooth phone-out-of-range auto-lock) ---
# Bluetooth is disabled anyway but belt-and-braces.
$winLogonPolicy = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winLogonPolicy -Name "EnableGoodbye" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

# --- 16d. Disable account lockout after failed password attempts ---
# Critical for unattended VNC access - we don't want Holly's account locked for 30min
# if a port scanner or fat-fingered VNC attempt fails the password too many times.
# Setting threshold to 0 disables lockout entirely.
& net accounts /lockoutthreshold:0 | Out-Null

# --- 16e. Force "never auto-reboot for updates" - belt and braces over active hours ---
$auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
Set-ItemProperty -Path $auPath -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $auPath -Name "AlwaysAutoRebootAtScheduledTime" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

# --- 16f. Power button: do nothing (avoid accidental shutdown if someone bumps it) ---
# Sets both AC and DC power button actions to "Do nothing" (action code 0).
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0
# Sleep button also disabled
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 0
# Lid close (if NUC has one - some do): also do nothing
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
# Critical battery action: do nothing (don't hibernate on power blip)
powercfg /setacvalueindex SCHEME_CURRENT SUB_BATTERY BATACTIONCRIT 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BATTERY BATACTIONCRIT 0
# Apply changes
powercfg /setactive SCHEME_CURRENT

# --- 16g. Ensure Tailscale and TightVNC services are set to auto-start and restart on failure ---
# Both should be installed by this point but Tailscale sometimes registers its service
# slightly later than its install completes, so we retry with a wait for any missing ones.
foreach ($svc in @("Tailscale", "tvnserver")) {
    # Wait up to 30s for the service to appear (handles slow service registration after install)
    $service = $null
    $waited = 0
    while (-not $service -and $waited -lt 30) {
        $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if (-not $service) {
            Start-Sleep -Seconds 3
            $waited += 3
        }
    }

    if ($service) {
        Set-Service -Name $svc -StartupType Automatic
        # sc.exe failure action: restart after 5 seconds, on 1st/2nd/3rd failure, reset counter daily
        & sc.exe failure $svc reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
        Write-Host "      service: $svc -> auto-start, restart-on-failure" -ForegroundColor DarkGray
    } else {
        Write-Host "      service: $svc -> not found after 30s wait (configure manually with: sc.exe failure $svc reset= 86400 actions= restart/5000/restart/5000/restart/5000)" -ForegroundColor Yellow
    }
}

# --- 16h. Disable "Show Lock Screen background picture on the sign-in screen" ---
# Avoids any flicker / fancy animation that might confuse VNC rendering.
Set-ItemProperty -Path $personalization -Name "NoLockScreenSlideshow" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

Write-OK "Bulletproofing applied - PC should stay reachable in all conditions"

# ============================================================================
# 17. DISABLE USB AUTORUN
# ============================================================================
Write-Step "Disabling USB autorun/autoplay"
$autoplay = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
if (-not (Test-Path $autoplay)) { New-Item -Path $autoplay -Force | Out-Null }
Set-ItemProperty -Path $autoplay -Name "NoDriveTypeAutoRun" -Value 0xFF -Type DWord -Force
Set-ItemProperty -Path $autoplay -Name "NoAutorun"          -Value 1    -Type DWord -Force
Write-OK "Autorun disabled"

# ============================================================================
# 18. TIME SYNC - keep clock accurate for TLS / AWS API calls
# ============================================================================
Write-Step "Configuring Windows time service to sync regularly"
Start-Service w32time -ErrorAction SilentlyContinue
Set-Service  w32time -StartupType Automatic
& w32tm /config /manualpeerlist:"time.windows.com,0x1 pool.ntp.org,0x1" /syncfromflags:manual /update | Out-Null
& w32tm /resync | Out-Null
Write-OK "Time sync configured"

# ============================================================================
# 19. HIDE MOUSE CURSOR WHEN IDLE
# ============================================================================
Write-Step "Setting up auto-hide for mouse cursor"
# Strategy: install AutoHotkey v2 + drop the script in C:\code, then create a
# Startup shortcut that explicitly invokes AutoHotkey64.exe with the script as
# an argument. We do NOT rely on the .ahk file association — Windows often fails
# to register that during silent installs, which causes the "How do you want to
# open this file?" dialog on every boot.

$ahkInstalled = $false
if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "    Installing AutoHotkey..."
    winget install --id AutoHotkey.AutoHotkey --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Start-Sleep -Seconds 2  # give it a moment to finish writing files
}

# Locate AutoHotkey64.exe - winget may install to either of these paths depending on scope
$ahkExeCandidates = @(
    "${env:ProgramFiles}\AutoHotkey\v2\AutoHotkey64.exe",
    "${env:ProgramFiles}\AutoHotkey\AutoHotkey64.exe",
    "${env:LOCALAPPDATA}\Programs\AutoHotkey\v2\AutoHotkey64.exe",
    "$env:USERPROFILE\AppData\Local\Programs\AutoHotkey\v2\AutoHotkey64.exe"
)
$ahkExe = $ahkExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($ahkExe) {
    $ahkInstalled = $true
    Write-Host "      Found AutoHotkey at: $ahkExe" -ForegroundColor DarkGray
} else {
    Write-Warn "AutoHotkey64.exe not found after install - cursor auto-hide will not work"
}

$ahkScript = @'
; Hide cursor after 3 seconds of inactivity. Show again on any mouse movement.
#Requires AutoHotkey v2.0
#SingleInstance Force

idleTimeout := 3000   ; ms before hiding
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
$ahkScript | Out-File -FilePath $ahkPath -Encoding UTF8 -Force

# Put a SHORTCUT in holly's Startup folder, not the .ahk file directly.
# The shortcut explicitly invokes AutoHotkey64.exe with the script path as an argument,
# which works regardless of whether .ahk files are properly associated.
$hollyStartup = "C:\Users\holly\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
if (-not (Test-Path $hollyStartup)) {
    Write-Warn "holly's Startup folder not found - profile may not exist yet. Re-run after first holly login."
} elseif (-not $ahkInstalled) {
    Write-Warn "AutoHotkey not installed - skipping cursor auto-hide setup"
} else {
    # Remove any old .ahk file that may have been dropped here by a previous script version
    $oldDirectPath = "$hollyStartup\hide-cursor.ahk"
    if (Test-Path $oldDirectPath) {
        Remove-Item $oldDirectPath -Force -ErrorAction SilentlyContinue
        Write-Host "      Removed old hide-cursor.ahk from Startup (replacing with shortcut)" -ForegroundColor DarkGray
    }

    # Create the shortcut: target = AutoHotkey64.exe, arguments = path to script
    $shortcutPath = "$hollyStartup\hide-cursor.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($shortcutPath)
    $sc.TargetPath = $ahkExe
    $sc.Arguments = "`"$ahkPath`""
    $sc.WorkingDirectory = "C:\code"
    $sc.WindowStyle = 7   # 7 = minimised - no console flash
    $sc.Description = "Auto-hide cursor when idle"
    $sc.Save()
    Write-OK "Cursor auto-hide installed (shortcut in Startup - no file association needed)"
}

# Also fix the .ahk file association globally as belt-and-braces, in case anything else
# tries to open .ahk files later. This sets the default app for .ahk files to AutoHotkey64.exe.
if ($ahkInstalled) {
    $ahkFileAssoc = "HKLM:\SOFTWARE\Classes\.ahk"
    $ahkClassAssoc = "HKLM:\SOFTWARE\Classes\AutoHotkeyScript\shell\open\command"
    try {
        if (-not (Test-Path $ahkFileAssoc)) { New-Item -Path $ahkFileAssoc -Force | Out-Null }
        Set-ItemProperty -Path $ahkFileAssoc -Name "(Default)" -Value "AutoHotkeyScript" -Force
        if (-not (Test-Path $ahkClassAssoc)) { New-Item -Path $ahkClassAssoc -Force | Out-Null }
        Set-ItemProperty -Path $ahkClassAssoc -Name "(Default)" -Value "`"$ahkExe`" `"%1`"" -Force
    } catch {
        # Non-fatal - the shortcut approach above doesn't need this to work
    }
}

# ============================================================================
# 20. TAILSCALE AUTO-CONNECT (if auth key provided)
# ============================================================================
if ($TailscaleAuthKey) {
    Write-Step "Connecting Tailscale with auth key"
    $tailscale = "${env:ProgramFiles}\Tailscale\tailscale.exe"
    if (Test-Path $tailscale) {
        # --unattended keeps the connection alive even when Holly is logged out
        # --hostname matches our PC name so it shows up nicely in the admin console
        & $tailscale up --authkey=$TailscaleAuthKey --unattended --hostname=$NewHostname --accept-routes
        Write-OK "Tailscale connected - check admin console at https://login.tailscale.com/admin/machines"
    } else {
        Write-Warn "Tailscale not installed yet - sign in manually after reboot"
    }
} else {
    Write-Warn "No Tailscale auth key provided - you'll need to sign in manually on each PC"
}

# ============================================================================
# 21. FINAL: DISABLE WIFI + BLUETOOTH
# ============================================================================
Write-Step "Disabling Wi-Fi and Bluetooth adapters"
# Wifi: disable the radio + the adapter
Get-NetAdapter -Physical | Where-Object { $_.PhysicalMediaType -like "*802.11*" -or $_.Name -like "*Wi-Fi*" -or $_.Name -like "*Wireless*" } | ForEach-Object {
    Disable-NetAdapter -Name $_.Name -Confirm:$false
    Write-Host "      disabled: $($_.Name)" -ForegroundColor DarkGray
}

# Bluetooth: disable all BT devices via PnP
Get-PnpDevice -Class "Bluetooth" -ErrorAction SilentlyContinue | ForEach-Object {
    Disable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "      disabled: $($_.FriendlyName)" -ForegroundColor DarkGray
}
Write-OK "Wireless disabled"

# ============================================================================
# DONE
# ============================================================================
Write-Step "Restarting Explorer to apply UI changes"
Stop-Process -Name explorer -Force
Start-Sleep -Seconds 2

Write-Host "`n=== Setup complete for $NewHostname ===" -ForegroundColor Magenta
Write-Host "Manual steps remaining:" -ForegroundColor Yellow
Write-Host "  1. Reboot now (hostname change requires it)" -ForegroundColor Yellow
Write-Host "  2. After reboot, plug in ethernet and run Windows Update manually" -ForegroundColor Yellow
Write-Host "  3. Clone your git repo into C:\code" -ForegroundColor Yellow
if (-not $TailscaleAuthKey) {
    Write-Host "  4. Sign in to Tailscale (run 'tailscale login' or use the GUI)" -ForegroundColor Yellow
}
Write-Host "  5. Open OBS once to set up the virtual camera" -ForegroundColor Yellow

Stop-Transcript | Out-Null

$reboot = Read-Host "`nReboot now? (y/n)"
if ($reboot -eq "y") { Restart-Computer -Force }