# Holly PC Setup

Automated setup script for new Holly NUC PCs. Run after Windows OOBE to debloat the machine, lock it down, install required apps, and onboard it to the fleet.

New to this? Start with the **[setup guide](https://henry-venaglass.github.io/pc-setup/setup-explainer.html)** — a plain-English web page explaining what the script does and how to run it, with a download button for the script (follow it from the new PC's browser). For the full fleet architecture — how the scripts fit together, the kiosk watchdog, and the AWS IoT Greengrass delivery/monitoring layer — see the **[fleet runbook](https://henry-venaglass.github.io/pc-setup/fleet-runbook.html)**.

## Before you start

You'll need:

- The NUC, with power, monitor, keyboard, mouse, and ethernet cable
- USB stick containing `setup.ps1` (or download it from the [setup guide](https://henry-venaglass.github.io/pc-setup/setup-explainer.html) on the PC)
- The PC number for this machine (e.g. `001`, `002`, `003`)
- The fleet password (not written in this repo — it's public)
- A Tailscale auth key and the provisioning AWS access key + secret (for Greengrass enrolment)
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
- Password: the standard fleet password (deliberately not written here — this repo is public)
- Security questions: pick any three, answer with the fleet password
- Say **No** to every privacy and Cortana question

## Step 2 — Connect ethernet

Once you're at the desktop, plug in the ethernet cable.

## Step 3 — Run the setup script

Get `setup.ps1` onto the PC — either plug in the USB stick, or download it from GitHub directly on the PC. Save it to the Downloads folder (`C:\Users\holly\Downloads`).

Right-click the Start button and open **Terminal (Admin)**. Run these three commands, one at a time:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\Users\holly\Downloads
.\setup.ps1 -PCNumber xxx -HollyPassword "..." -AuthKey "tskey-auth-..." -AwsAccessKey "AKIA..." -AwsSecretKey "..."
```

Replace `xxx` with this PC's number (`001`, `002`, etc.), `-HollyPassword` with the fleet password exactly as typed during OOBE, `tskey-auth-...` with the Tailscale auth key, and the AWS keys with a temporary access key from the AWS account (used only during Greengrass enrolment, then cleared from the machine). The script takes 15–30 minutes. When it asks to reboot, say yes.

As well as everything else, the script registers the watchdog (which launches and supervises the app during kiosk hours) and enrols the PC into AWS IoT Greengrass as `holly-xxx` in the `holly-fleet` group — which is how app code gets onto the machine.

## Step 4 — Run Windows Update

After reboot, open **Settings → Windows Update** and click **Check for updates**. Install everything, reboot when prompted, and repeat until no updates remain.

## Step 5 — Verify Tailscale, VNC, and Greengrass

From a different machine (e.g. your laptop):

- Open the Tailscale admin console — confirm `HOLLY-xxx` appears, tagged `holly-pc`, and is online
- Open TightVNC Viewer and connect to its tailnet IP
- Enter the VNC password and confirm you see holly's desktop
- Open the AWS console → IoT Core → Greengrass → Core devices — confirm `holly-xxx` shows **Healthy**

## Step 6 — Get the app code on and test it

The app code arrives via Greengrass: a newly enrolled PC automatically pulls the fleet's current deployment (or run `./publish.sh` from your Mac to push a fresh release). Wait a few minutes, then confirm `C:\code\holly` exists on the PC.

Test it runs end-to-end: open PowerShell as `holly`, `cd C:\code\holly\projects\holly-local`, and run `uv run holly`. Close it when happy — the watchdog task (registered by setup.ps1) will launch and supervise it automatically during kiosk hours (Mon–Fri 08:30–18:00).

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
- The watchdog starts, and (during kiosk hours, Mon–Fri 08:30–18:00) launches the Holly app
- OBS virtual camera is active

## Step 10 — Label the PC

Print a label with this PC's name (e.g. `HOLLY-001`) and stick it on the bottom of the box so you can easily tell which PC is which.

## Releasing code to the fleet

From your Mac:

```bash
./publish.sh          # auto-bumps the version, deploys to every PC in holly-fleet
./publish.sh 1.4.0    # or publish an explicit version
```

Each release is a numbered Greengrass component version — PCs pull it themselves (even ones that were offline when you published). Rollouts are staged with auto-abort: devices update a few at a time, speeding up as updates succeed, and if the first devices fail the rollout cancels itself (failed devices roll back to the previous version). The watchdog script ships inside every release too, so watchdog fixes reach the whole fleet the same way.

The new code lands in `C:\code\holly` immediately but is picked up when the app next starts: either the next 08:30 launch, or kill the app once over VNC and the watchdog relaunches it on the new code within seconds.

There's a one-time AWS setup (artifact bucket + device read access) documented at the top of `publish.sh`.

## Final checklist

- [ ] PC name shows as `HOLLY-xxx`
- [ ] User account is `holly` in lowercase
- [ ] PC visible in Tailscale admin console, tagged `holly-pc`
- [ ] PC shows **Healthy** in AWS Greengrass → Core devices as `holly-xxx`
- [ ] App code present at `C:\code\holly` (delivered by Greengrass)
- [ ] `Holly-Watchdog` task exists in Task Scheduler (runs at holly's logon)
- [ ] VNC works from a remote machine over the tailnet IP
- [ ] PC reboots without manual interaction
- [ ] `holly` auto-logs in, no password prompt
- [ ] OBS virtual camera is active
- [ ] Wifi and Bluetooth disabled
- [ ] Windows Update fully complete
- [ ] PC is physically labeled with the corresponding name `HOLLY-xxx`
