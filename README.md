# GIGABYTE (Clevo barebone) RGB keyboard backlight on Linux

Get the built-in RGB keyboard backlight working on **GIGABYTE gaming laptops**
under Linux — no vendor software, no Wine, no reverse engineering.

GIGABYTE gaming laptops are rebranded **Clevo barebones**, so the keyboard is
driven by TUXEDO's Clevo ACPI/WMI drivers. Those drivers ship in the
`tuxedo-drivers` package and are already on most systems — they just refuse to
load, because a DMI compatibility gate only accepts `TUXEDO`-branded machines.
A GIGABYTE DMI vendor fails the check, so `tuxedo_keyboard` aborts with
`-ENODEV` and the keyboard stays dark.

This project is a **10-line patch** that adds GIGABYTE to that allow-list, plus
the tooling to make it usable and survive reboots and upgrades.

> **This is not a driver.** It patches an existing GPL driver written by
> [TUXEDO Computers](https://gitlab.com/tuxedocomputers/development/packages/tuxedo-drivers).
> All hardware communication is their code. See [Credits](#credits).

---

## Does this work on my laptop?

Two checks:

```bash
# 1. Is it a GIGABYTE machine?
cat /sys/class/dmi/id/sys_vendor          # expect: GIGABYTE

# 2. Does it expose the Clevo WMI interface?
ls /sys/bus/wmi/devices/ | grep ABBC0F6B  # expect: ABBC0F6B-8EA1-11D1-00A0-C90629100000
```

If both match, it should work. If the GUID is missing, this will not help you —
your keyboard is wired differently.

### Confirmed working

| Model | CPU | Distro | Kernel | Reported by |
|---|---|---|---|---|
| G6 KF (2024), SKU `RC56KF`, BIOS `FD10` | i7-13620H | Ubuntu 26.04 | 7.0.0-111034-tuxedo | [@devansh0703](https://github.com/devansh0703) |

**Untested but likely to work:** other GIGABYTE/AORUS laptops that pass both
checks above. If you try it, please
[open an issue](https://github.com/devansh0703/gigabyte-clevo-rgb-linux/issues)
with the two outputs above plus your model and kernel, so this table grows.

---

## Install

```bash
git clone https://github.com/devansh0703/gigabyte-clevo-rgb-linux
cd gigabyte-clevo-rgb-linux
sudo ./install.sh
```

The script detects your distribution, installs build dependencies, fetches the
upstream driver source, applies the patch, builds it with DKMS, loads it, and
installs the CLI + boot config.

**Supported:** Debian, Ubuntu, Mint, Pop!\_OS, Fedora, RHEL, Arch, Manjaro,
EndeavourOS, openSUSE — anything with DKMS and kernel headers.

To remove it:

```bash
sudo ./install.sh --uninstall
```

### Secure Boot

If Secure Boot is enabled, DKMS signs the module with your MOK key. If that key
is not enrolled the module will fail to load with
`Key was rejected by service`. Enroll it with:

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
# reboot and complete the MOK enrolment screen
```

---

## Usage

```bash
g6rgb blue                    # set a colour
g6rgb 255 0 0                 # arbitrary RGB (0-255)
g6rgb red|green|blue|white|cyan|magenta|yellow|orange|purple
g6rgb on | off                # backlight on/off
g6rgb bright 128              # brightness only (0-255)
g6rgb status                  # show current state
g6rgb cycle                   # cycle through colours
```

Or write to sysfs directly:

```bash
LED=/sys/class/leds/rgb:kbd_backlight
echo 255       > $LED/brightness
echo "0 0 255" > $LED/multi_intensity
```

Write `brightness` before `multi_intensity`: brightness goes through a separate
firmware call, and the colour write re-sends the colour.

### No sudo

By default the sysfs files are root-only. The installer adds a udev rule
granting the `video` group write access. Add yourself and re-login:

```bash
sudo usermod -aG video $USER
```

---

## Persisting your colour

The driver sets the backlight to **white** at load, so your colour resets on
reboot. To set your own default, create a small systemd unit:

```bash
sudo tee /etc/systemd/system/g6rgb-restore.service >/dev/null <<'EOF'
[Unit]
Description=Restore GIGABYTE keyboard backlight colour
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/g6rgb 0 0 255

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable --now g6rgb-restore.service
```

Replace `0 0 255` with your colour.

---

## Limitations

- **Static colour + brightness only.** These are 1-zone RGB keyboards. Effects
  like BREATHE / WAVE / CYCLE are 3-zone-only and not available on this hardware.
- **OpenRGB is not involved and not needed.** It will report no devices plus
  i2c/SMBus warnings. That is expected — the internal keyboard is reached over
  ACPI/WMI, not SMBus. Ignore those warnings.
- **A `tuxedo-drivers` package upgrade reverts the patch.** Your distro's
  `tuxedo-drivers` package overwrites `/usr/src/tuxedo-drivers-*`. Re-run
  `sudo ./install.sh` after such an upgrade.
- **Untested on other models.** See the compatibility table above.

---

## How it works

```
g6rgb (bash)                     writes numbers into sysfs
   │
   ▼
/sys/class/leds/rgb:kbd_backlight/     kernel LED class (multicolour)
   │
   ▼
tuxedo_keyboard.ko               builds the Clevo command word   ─┐
clevo_wmi.ko / clevo_acpi.ko     ACPI/WMI transport               ├ TUXEDO's code
   │                                                              │
   ▼                                                             ─┘
Embedded Controller (EC)         drives the LEDs
   │
   ▼
keyboard lights up
```

The patch only affects the **first gate** — whether the driver is allowed to
load at all. Everything below it is untouched upstream code.

### The patch

```diff
 static const struct dmi_system_id tuxedo_dmi_string_match[] = {
 	{ .matches = { DMI_MATCH(DMI_CHASSIS_VENDOR, "TUXEDO"), }, },
+	{ .matches = { DMI_MATCH(DMI_SYS_VENDOR,     "GIGABYTE"), }, },
+	{ .matches = { DMI_MATCH(DMI_BOARD_VENDOR,   "GIGABYTE"), }, },
+	{ .matches = { DMI_MATCH(DMI_CHASSIS_VENDOR, "GIGABYTE"), }, },
 	{ }
 };
```

An explicit per-vendor opt-in — **not** a blanket bypass of the compatibility
check. See [`patches/`](patches/) for the full patch with rationale.

### Verifying it works

```bash
lsmod | grep -E 'clevo|tuxedo'           # clevo_wmi, tuxedo_keyboard loaded
ls /sys/class/leds/ | grep rgb           # rgb:kbd_backlight
sudo dmesg | grep -i tuxedo              # 'Set Color 0x... for region 0xf0000000'
```

Enable driver tracing to watch the actual ACPI traffic:

```bash
sudo sh -c 'echo "module tuxedo_keyboard +p" > /sys/kernel/debug/dynamic_debug/control'
sudo dmesg -w
```

---

## Safety

**Read this before installing on a machine that is not the confirmed model.**

The compatibility check exists for a reason. TUXEDO state that the EC code "can
brick devices and therefore must be ensured to only run on compatible and tested
devices". This patch narrows that gate to a specific vendor rather than removing
it, but it is still **you** accepting the risk on **your** hardware.

- Tested only on the model listed above.
- The patch touches nothing but the allow-list; no command bytes are changed.
- If your model is not listed, you are an early tester. Back up first.

---

## Credits

Almost all of the work here is **TUXEDO Computers'**. They wrote the driver, the
Clevo WMI/ACPI transport, and the LED class integration — and they did it under
GPL-2.0-or-later so this kind of fix is possible.

- Upstream: <https://gitlab.com/tuxedocomputers/development/packages/tuxedo-drivers>

Related community projects doing similar things — if this repo doesn't fit your
machine, one of these might:

- [commown/tuxedo-drivers](https://gitlab.com/commown/tuxedo-drivers) — maintains
  an explicit per-vendor allow-list (TUXEDO, WHYOPENCOMPUTING, PCSpecialist,
  Ekimia, Notebook). Same design as this patch.
- [wessel-novacustom/clevo-keyboard](https://github.com/wessel-novacustom/clevo-keyboard)
  — for coreboot/Dasharo Clevo machines.
- [nick42d/clevo-drivers](https://github.com/nick42d/clevo-drivers) — Arch AUR,
  removes the check entirely.
- [JAmanOG/colorful-p15-keyboard-backlight](https://github.com/JAmanOG/colorful-p15-keyboard-backlight)
  — CLI + GUI for COLORFUL/Tongfang laptops.

## License

**GPL-2.0-or-later** — see [LICENSE](LICENSE).

Required, not optional: the patch modifies TUXEDO's GPL-2.0-or-later source and
is therefore a derivative work.
