# VARA On A Stick

Bash helpers to build a **headless Debian** VARA modem appliance. It relies on Xvfb to create a virtual display, Wine to run VARA FM/HF, and [varanny](https://github.com/islandmagic/varanny) for orchestration. A Wi-Fi Access Point is automatically created so it can be used in the field.

Target hardware is meant to be compact PCs (e.g. [HIGOLEPC Mini PC Stick](https://goleminipc.com/products/higolepc-mini-pc-stick-intel-celeron-j4115-windows-11-usb-pd3-0-hdmi-4k-gigabit-ethernet-wifi-5-0-bt-5-2-for-office-home?variant=45594960986392)); headless Linux runs well on modest RAM (e.g. 4 GB).

Everything lives under **`/opt/vara`**. 

---

## 0. Install Debian (no desktop)

1. Download the [Debian 13](https://www.debian.org/download) ISO; write it to USB (`dd`, [balenaEtcher](https://etcher.balena.io/), or the installer’s copy tool).
2. Boot the machine from USB and run the installer.

**Installer choices:**

| Choice | Recommendation |
|--------|------------------|
| Hostname | `VARA-Modem` |
| Root password | Disabled — use `sudo` and user `ham` |
| User | Normal account **`ham`** |
| Disk | Guided — entire disk |
| Software | **SSH server** + **standard system utilities**; **no** desktop (uncheck GNOME, KDE, Xfce, …) |

3. Reboot into the installed system.

**On the console**, enable SSH and note the LAN IP in case you need it. 

```bash
sudo systemctl enable ssh
sudo systemctl start ssh
ip a
sudo reboot
```

---

## 1. Clone this repo on the target

From your workstation:

```bash
ssh ham@vara-modem.local
```

On the target:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/islandmagic/vara-on-a-stick.git
cd vara-on-a-stick
```

---

## 2. Recipe

Scripts are idempotent. If something fails or you skipped a step, re-run the script.

| Step | Command |  |
|------|---------|----------------|
| 1 | `sudo ./setup-headless-prereqs.sh` | Install dependencies, creates **`/opt/vara`** layout |
| 2 | `./setup-wine-for-vara.sh` | Wine + winetricks |
| 3 | `./download-vara-installers.sh` | Latest VARA FM/HF zips from Winlink → **`/opt/vara/installers`** |
| 4 | `./install-vara.sh` | Silent Wine install of VARA FM/HF; **Takes a while!** |
| 5 | `./create-vara-ini-digirig-lite.sh` | Creates VARA profile for **Digirig Lite**. Set **`VARA_CALLSIGN`** and **`VARA_REGISTRATION_CODE`** to skip prompts |
| 5a (optional) | `./create-vara-ini-all-in-one-cable.sh` | Creates VARA profile for **All In One Cable** |
| 5b (optional) | `sudo ./setup-ic705.sh` | Creates VARA profile for **Icom IC-705** |
| 6 | `sudo ./install-varanny.sh` | Builds varanny and config file |
| 7 | `sudo ./setup-wifi-ap.sh` | Setup a Wi‑Fi AP named **VARA-Modem** (psw: **varamodem**) |
| 8 | `sudo reboot` | |

**If something goes wrong**

| Situation | Command |
|-----------|---------|
| Stuck Wine / installer | `./stop-vara-wine.sh` add **`--force`** if needed |
| Reset Wine + VARA data (keep varanny) | `./wipe-vara-wine.sh` |
| Nuke **`/opt/vara`** | `./wipe-vara-wine.sh --all` |

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

## Install-vara: timing, noise, and success

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

### How you know it succeeded

With **`create-vara-launchers.sh`** beside **`install-vara.sh`**, a good run ends like this (noise above does not cancel success):

```
Installed:
  /opt/vara/libexec/vara-fm
  /opt/vara/libexec/vara-hf
Add to PATH, e.g. in ~/.profile:
  export PATH="/opt/vara/libexec:$PATH"

Done. Inno logs: /opt/vara/logs
```

---

## See also

- Script headers and **`-h` / `--help`** on each script.
