# add-ssh.ps1  -  run once on each already-set-up NUC, in an ADMIN PowerShell
$DeployPublicKey = @(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUoRwbcyxf+RYrOCIy8QtlA/XJE47E4WtjS/ijQZ9xV fleet-deploy"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIVVR3cXtI2JmniyxsMkTALvsUuBGExVU8T5tvf5yuZD fleet_deploy"
)

# 1. Install the OpenSSH server
$cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }

# 2. Start it, auto-start on boot, restart on failure
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd
& sc.exe failure sshd reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null

# 3. Make PowerShell the default SSH shell
if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) { New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null }
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -Type String -Force

# 4. Firewall rule for port 22 (usually auto-created, this is belt-and-braces)
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH SSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# 5. Authorize your Mac's key (holly is an admin, so it goes in the admin file)
$akFile = "C:\ProgramData\ssh\administrators_authorized_keys"
Set-Content -Path $akFile -Value $DeployPublicKey -Encoding ascii -Force
& icacls $akFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

Write-Host "Done. Test from your Mac:  ssh -i ~/.ssh/fleet_deploy holly@<hostname>" -ForegroundColor Green