# VARA On A Stick

Bash helpers to build a **headless Debian** VARA node: Xvfb, Wine, Winlink **VARA FM/HF**, Wi-Fi AP, and [varanny](https://github.com/islandmagic/varanny) with per–sound-card profile INIs.

Target hardware can be compact PCs (e.g. [HIGOLEPC Mini PC Stick](https://goleminipc.com/products/higolepc-mini-pc-stick-intel-celeron-j4115-windows-11-usb-pd3-0-hdmi-4k-gigabit-ethernet-wifi-5-0-bt-5-2-for-office-home?variant=45594960986392)); headless Linux runs well on modest RAM (e.g. 4 GB).

**Where files live:** Installers, logs, profiles, Wine prefix (`wineprefixes/vara`), launchers, and `wine.env` are under **`/opt/vara`** (tree created by `setup-headless-prereqs.sh`). Scripts honor `VARA_ROOT`, `VARA_INSTALLERS_DIR`, and related env vars. 

---

## 0. Install Debian

1. Download the [Debian 13](https://www.debian.org/download) ISO; write it to USB (`dd`, [balenaEtcher](https://etcher.balena.io/), or the installer’s copy tool).
2. Boot the machine from USB and run the installer.

**Installer choices:**

| Choice | Recommendation |
|--------|------------------|
| Hostname | `VARA-Modem` |
| Root password | Disabled — use `sudo` and user `ham` |
| User | Normal account **`ham`** (lab password ok; change if exposed) |
| Disk | Guided — entire disk |
| Software | **SSH server** + **standard system utilities**; **no** desktop (uncheck GNOME, KDE, Xfce, …) |

3. Reboot into the installed system.

**On the console** — enable SSH and note the LAN IP:

```bash
sudo systemctl enable ssh
sudo systemctl start ssh
ip a
```

Use the IPv4 on your Ethernet/Wi‑Fi interface (e.g. `eth0`, `enp0s3`, `wlan0`) for SSH below.

---

## 1. Clone this repo on the target

From your workstation:

```bash
ssh ham@<IP>
```

On the target:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/islandmagic/vara-on-a-stick.git
cd vara-on-a-stick
```

The recipe below assumes **`cd` into this directory** (or use full paths to the scripts).

---

## 2. Recipe: setup scripts in order

You need user **`ham`**, **`sudo`**, and a shell **in the repo clone**.

### Who runs what

| Step | Who | Command | What it does |
|------|-----|---------|----------------|
| 1 | user with `sudo` | `./setup-headless-prereqs.sh` | Apt packages, **Xvfb on `:1`** as `ham`, tools (`jq`, Go, …); creates **`/opt/vara`** layout |
| 2 | `ham` | `./setup-wine-for-vara.sh` | Wine + winetricks + **32-bit prefix**; writes **`/opt/vara/config/wine.env`** — needs a display (usually **`DISPLAY=:1`**) |
| 3 | `ham` | `./download-vara-installers.sh` | Latest VARA FM/HF zips from Winlink → **`/opt/vara/installers`** |
| 4 | `ham` | `./install-vara.sh` | Silent Wine install of FM/HF; writes **`/opt/vara/libexec/vara-fm`** and **`vara-hf`** if **`create-vara-launchers.sh`** is in the same directory. **Slowest step** — see [Install-vara (step 4)](#install-vara-step-4-timing-noise-and-success) |
| 5 | `ham` | `./create-vara-ini-digirig-lite.sh` **and/or** `./create-vara-ini-all-in-one-cable.sh` | Profile INIs under **`/opt/vara/profiles/…`** (only for hardware you use). **Non-interactive:** set **`VARA_CALLSIGN`** and **`VARA_REGISTRATION_CODE`** when stdin is not a TTY |
| 6 | root (from repo) | `sudo ./install-varanny.sh` | Builds varanny → **`/opt/vara/bin/varanny`**, writes **`/opt/vara/config/varanny.json`**, installs **`varanny.service`**. Needs **`jq`**. DNS-SD lists FM+HF **only** for profiles that have **both** **`varafm.ini`** and **`vara.ini`**. **At least one complete profile is required** |
| 7 | root | `sudo ./setup-wifi-ap.sh` | Wi‑Fi AP (**hostapd** + **dnsmasq**); **`--install-deps`** if packages missing. **Conflicts** with NetworkManager on the same WLAN unless you unmanage that interface |
| 8 | root or `ham` with `sudo` | `sudo reboot` | **Finish here:** full boot so **Xvfb**, **varanny**, and kernel/network changes come up cleanly |

**If something goes wrong**

| Situation | Who | Command |
|-----------|-----|---------|
| Stuck Wine / installer | `ham` (not root) | `./stop-vara-wine.sh` — add **`--force`** if needed |
| Reset Wine + VARA data (keep varanny) | `ham` (not root) | `./wipe-vara-wine.sh` — see **`-h`**; optional **`--strip-bashrc`**. Removes prefix, installers, logs, profiles, **`libexec/*`**, **`wine.env`** — **not** **`bin/varanny`**, **`varanny.json`**, **`varanny.service`** |
| Nuke **`/opt/vara`** + varanny unit | `ham` with `sudo` or root | `./wipe-vara-wine.sh --all` — removes all of **`VARA_ROOT`**, **`varanny.service`**, and **`~/.config/vara`** for the VARA user — see **`-h`** |

### Commands in order (copy-paste skeleton)

Adjust step 5 for your hardware (one or both profile scripts). Step 7 only if you want the AP.

```bash
sudo ./setup-headless-prereqs.sh

./setup-wine-for-vara.sh
./download-vara-installers.sh
./install-vara.sh
./create-vara-ini-digirig-lite.sh          
# and/or ./create-vara-ini-all-in-one-cable.sh

sudo ./install-varanny.sh

sudo ./setup-wifi-ap.sh

sudo reboot
```

`install-varanny.sh` copies **`create-vara-ini-*.sh`** and **`create-vara-launchers.sh`** to **`/opt/vara/scripts/`** when present. To add a second radio later, create the missing INIs under **`/opt/vara/profiles/`** and run **`sudo ./install-varanny.sh`** again.

**Script options:** run **`./<script> -h`** or **`--help`** for flags and environment variables. **`create-vara-launchers.sh`** (same repo) rebuilds **`/opt/vara/libexec/vara-fm`** and **`vara-hf`** after a VARA reinstall or path change — **`install-vara.sh`** runs it automatically when the file sits next to **`install-vara.sh`** in the clone.

---

## Visual VARA / Wine over SSH (optional)

Normally **Xvfb** on **`DISPLAY=:1`** (from **`wine.env`**) is enough for unattended installs and varanny. For a **real window** (dialogs, VARA GUI, interactive winetricks), use **X11 forwarding** from a machine with an X server (Linux desktop, [XQuartz](https://www.xquartz.org/) on macOS, or Windows X).

1. **SSH with forwarding** (trusted forwarding works better with Wine):

   ```bash
   ssh -Y ham@<IP>
   ```

   Prefer **`-Y`** over **`-X`** if windows fail to open.

2. **Confirm `DISPLAY`** on the modem:

   ```bash
   echo "$DISPLAY"
   ```

   Typical: `localhost:10.0`. If empty: enable **`ForwardX11`** on the client and **`X11Forwarding yes`** in **`/etc/ssh/sshd_config`** on the server (default with **`openssh-server`** on Debian).

3. **This shell only** — load env, match SSH’s `DISPLAY`, run VARA (do **not** permanently edit **`wine.env`** if varanny should keep using Xvfb):

   ```bash
   source /opt/vara/config/wine.env
   export DISPLAY=localhost:10.0   # use the value from step 2
   /opt/vara/libexec/vara-fm
   # or: wine path/to/setup.exe
   ```

4. **Nothing draws?** On the client, verify an X server and test **`xeyes`** / **`xclock`** over the same **`ssh -Y`** session.

---

## Install-vara (step 4): timing, noise, and success

### Timeouts and “hangs”

`install-vara.sh` is usually **much slower** than other steps. FM/HF installers may show **no new output** for a long time (CLR/MSI work) and look frozen — **let them run** unless you see a real failure or a stuck dialog. Each EXE uses a **timeout** (default **180 s**); if that cuts off a legitimate run, raise **`VARA_WINE_INSTALL_TIMEOUT_SEC`** or set it to **`0`** to disable. On errors, inspect **`/opt/vara/logs/`** (or whatever **`VARA_INSTALL_LOG_DIR`** / **`VARA_ROOT`** uses).

### stderr you can usually ignore

Large **Wine** spew often **does not** mean failure:

| Message pattern | Meaning |
|-----------------|--------|
| **`err:ole:CoGetContextToken apartment not initialised`**, **`err:ole:CoReleaseMarshalData`** / **`0x8001011d`** | Incomplete COM/OLE in Wine; installs often still succeed |
| **`err:eventlog:ReportEventW`** + **`.NET Runtime Optimization Service`** / **`PresentationFontCache`** / **`0x80131018`** | .NET “optimization” noise under Wine; often harmless |
| **`ntlm_auth was not found`** / **no NTLM support** | Install **`winbind`** (`sudo apt install winbind`); **`setup-wine-for-vara.sh`** pulls it in — clears warnings |
| **`err:msidb:TransformView_set_row`** | MSI transform noise — ignore unless the install actually fails |

### How you know step 4 succeeded

With **`create-vara-launchers.sh`** beside **`install-vara.sh`**, a good run ends like this (noise above does not cancel success):

```
Installed:
  /opt/vara/libexec/vara-fm
  /opt/vara/libexec/vara-hf
Add to PATH, e.g. in ~/.profile:
  export PATH="/opt/vara/libexec:$PATH"

Done. Inno logs: /opt/vara/logs
```

(Log path follows **`VARA_INSTALL_LOG_DIR`** / **`VARA_ROOT`** if you override defaults.)

---

## See also

- Script headers and **`-h` / `--help`** on each script.
