# Holly PC Setup

Automated setup script for new Holly NUC PCs. Run after Windows OOBE to debloat the machine, lock it down, install required apps, and onboard it to the fleet.

## Before you start

You'll need:

- The NUC, with power, monitor, keyboard, mouse, and ethernet cable
- USB stick containing `setup.ps1` (passwords and Tailscale auth key already filled in)
- The PC number for this machine (e.g. `001`, `002`, `003`)
- A label maker

## Step 1 — Windows Out-of-Box Experience

Power on the NUC. **Do not connect to wifi at any point.**

- Select region and keyboard
- When asked to connect to a network, click **"I don't have internet"**
- If Windows blocks you, press `Shift+F10`, run the command below, press Enter, then continue offline:
  ```
  OOBE\BYPASSNRO
  ```
- Choose **"Continue with limited setup"** if prompted
- Select **"Sign-in options" → "Offline account" → "Skip"** to avoid signing in with a Microsoft account
- Username: `holly` (all lowercase)
- Password: `holly`
- Security questions: pick any three, answer `holly` to all of them
- Say **No** to every privacy and Cortana question

## Step 2 — Connect ethernet

Once you're at the desktop, plug in the ethernet cable.

## Step 3 — Run the setup script

Get the script onto the PC — either plug in the USB stick, or download it from GitHub directly on the PC. Save it to the Downloads folder (`C:\Users\holly\Downloads`).

Right-click the Start button and open **Terminal (Admin)**. Run these three commands, one at a time:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\Users\holly\Downloads
.\setup.ps1 -PCNumber xxx
```

Replace `xxx` with this PC's number (`001`, `002`, etc.). The script takes 15–30 minutes. When it asks to reboot, say yes.

## Step 4 — Run Windows Update

After reboot, open **Settings → Windows Update** and click **Check for updates**. Install everything, reboot when prompted, and repeat until no updates remain.

## Step 5 — Verify Tailscale and VNC

From a different machine (e.g. your laptop):

- Open the Tailscale admin console — confirm `HOLLY-xxx` appears, tagged `holly-pc`, and is online
- Open TightVNC Viewer and connect to its tailnet IP
- Enter the VNC password and confirm you see holly's desktop

## Step 6 — Clone the repo and set up the app

Open PowerShell as `holly` and clone the repo into `C:\code`:

```powershell
cd C:\code
git clone <repo-url>
```

Install dependencies and test the app runs end-to-end. Once it works, edit `C:\code\launch-holly-app.bat` and put the real launch command in it (the script created a placeholder).

## Step 7 — Set up OBS for virtual camera only

Launch OBS Studio. When the Auto-Configuration Wizard appears on first run:

- Select **"I will only be using the virtual camera"**
- Click through the wizard, accepting defaults

## Step 8 — Disable built-in audio and camera devices

Open Device Manager (right-click Start → **Device Manager**) and disable the NUC's built-in devices so they don't get auto-selected later:

- Under **Audio inputs and outputs**: right-click each internal mic and speaker → **Disable device**
- Under **Cameras** (or **Imaging devices**): right-click the internal webcam (if present) → **Disable device**

## Step 9 — Reboot test

Restart the PC. The expected sequence with no intervention:

- No login prompt — holly's desktop appears automatically
- The Holly app launches
- OBS virtual camera is active

## Step 10 — Label the PC

Print a label with this PC's name (e.g. `HOLLY-001`) and stick it on the bottom of the box so you can easily tell which PC is which.

## Final checklist

- [ ] PC name shows as `HOLLY-xxx`
- [ ] User account is `holly` in lowercase
- [ ] PC visible in Tailscale admin console, tagged `holly-pc`
- [ ] VNC works from a remote machine over the tailnet IP
- [ ] PC reboots without manual interaction
- [ ] `holly` auto-logs in, no password prompt
- [ ] Mouse cursor hides after a few seconds idle
- [ ] OBS virtual camera is active
- [ ] Wifi and Bluetooth disabled
- [ ] Windows Update fully complete
- [ ] PC is physically labeled with the coresponding name 'HOLLY-xxx'
