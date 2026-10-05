#!/usr/bin/env bash
# install.sh — build & install the patched tuxedo_keyboard driver so the
# 1-zone RGB keyboard backlight works on GIGABYTE (Clevo barebone) laptops.
#
# Supports: Debian/Ubuntu/Mint/Pop, Fedora/RHEL, Arch/Manjaro/EndeavourOS,
#           openSUSE, and anything else with DKMS + kernel headers.
#
# Usage:  sudo ./install.sh [--driver-version X.Y.Z] [--uninstall]
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

UPSTREAM_REPO="https://gitlab.com/tuxedocomputers/development/packages/tuxedo-drivers"
DEFAULT_VERSION="4.24.0"
DRIVER_VERSION="$DEFAULT_VERSION"
WORKDIR="$(mktemp -d)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/0001-allow-gigabyte-dmi-vendor.patch"
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --driver-version) DRIVER_VERSION="$2"; shift 2 ;;
        --uninstall)      UNINSTALL=1; shift ;;
        -h|--help)        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()    { c_red "error: $*"; exit 1; }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"
[[ -f "$PATCH_FILE" ]] || die "patches/0001-allow-gigabyte-dmi-vendor.patch not found next to this script"

# ---------------------------------------------------------------- sanity checks
step "Checking this machine is a GIGABYTE Clevo barebone"

DMI_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)"
if [[ "$DMI_VENDOR" != *GIGABYTE* ]]; then
    c_ylw "warning: DMI system vendor is '$DMI_VENDOR', not GIGABYTE."
    c_ylw "This patch was written for GIGABYTE-branded Clevo barebones."
    read -rp "Continue anyway? [y/N] " a
    [[ "${a,,}" == y* ]] || die "aborted"
fi

# The drivers only make sense if the Clevo WMI interface is actually present.
if [[ -d /sys/bus/wmi/devices ]]; then
    if compgen -G "/sys/bus/wmi/devices/ABBC0F6B-*" > /dev/null; then
        c_grn "found Clevo WMI interface (ABBC0F6B) — hardware looks supported"
    else
        c_ylw "warning: Clevo WMI GUID ABBC0F6B not found in /sys/bus/wmi/devices/."
        c_ylw "The keyboard backlight may not be reachable on this model."
        read -rp "Continue anyway? [y/N] " a
        [[ "${a,,}" == y* ]] || die "aborted"
    fi
fi

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    c_ylw "Secure Boot is ENABLED."
    c_ylw "DKMS will sign modules with your MOK key. If the key is not enrolled,"
    c_ylw "the module will fail to load with 'Key was rejected by service'."
    c_ylw "See README -> Secure Boot."
fi

# ---------------------------------------------------------------- uninstall
if [[ $UNINSTALL -eq 1 ]]; then
    step "Uninstalling"
    for m in clevo_acpi clevo_wmi uniwill_wmi tuxedo_io tuxedo_keyboard tuxedo_compatibility_check; do
        modprobe -r "$m" 2>/dev/null || true
    done
    for v in $(dkms status tuxedo-drivers 2>/dev/null | grep -oP 'tuxedo-drivers/\K[^,]+' | sort -u); do
        dkms remove -m tuxedo-drivers -v "$v" --all >/dev/null 2>&1 || true
    done
    rm -f /etc/modules-load.d/tuxedo-keyboard.conf
    rm -f /etc/udev/rules.d/99-g6-kf-kbd-rgb.rules
    rm -f /usr/local/bin/g6rgb
    udevadm control --reload-rules 2>/dev/null || true
    c_grn "Removed the patched driver and config."
    c_ylw "Note: a distro 'tuxedo-drivers' package, if installed, is untouched."
    exit 0
fi

# ---------------------------------------------------------------- dependencies
step "Installing build dependencies"

if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq dkms git make gcc patch "linux-headers-$(uname -r)" \
        || apt-get install -y -qq dkms git make gcc patch linux-headers-generic
elif command -v dnf >/dev/null; then
    dnf install -y -q dkms git make gcc patch "kernel-devel-$(uname -r)" || \
        dnf install -y -q dkms git make gcc patch kernel-devel
elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm --needed dkms git make gcc patch linux-headers || \
        pacman -Sy --noconfirm --needed dkms git make gcc patch
elif command -v zypper >/dev/null; then
    zypper --non-interactive install dkms git make gcc patch kernel-devel
else
    c_ylw "unrecognised package manager — ensure dkms, git, make, gcc, patch and kernel headers are present."
fi

for t in dkms git patch; do
    command -v "$t" >/dev/null || die "$t is not available after install attempt"
done

# ---------------------------------------------------------------- fetch source
step "Fetching tuxedo-drivers $DRIVER_VERSION"
cd "$WORKDIR"
git clone -q --depth 1 --branch "v${DRIVER_VERSION}" "$UPSTREAM_REPO" src 2>/dev/null \
    || { c_ylw "tag v$DRIVER_VERSION not found, using default branch"; git clone -q --depth 1 "$UPSTREAM_REPO" src; }

cd src

# Upstream ships no dkms.conf; the distro packages generate one. We supply it.
if [[ -f dkms.conf ]]; then
    ACTUAL_VERSION="$(grep -oP 'PACKAGE_VERSION="\K[^"]+' dkms.conf | head -1)"
else
    ACTUAL_VERSION="$(grep -oP '^VERSION\s*:?=\s*\K[0-9][0-9.]*' Makefile package.yml 2>/dev/null | head -1 || true)"
fi
[[ -n "${ACTUAL_VERSION:-}" ]] || ACTUAL_VERSION="$DRIVER_VERSION"
echo "driver source version: $ACTUAL_VERSION"

# ---------------------------------------------------------------- apply patch
step "Applying GIGABYTE DMI allow-list patch"

TARGET="src/tuxedo_compatibility_check/tuxedo_compatibility_check.c"
[[ -f "$TARGET" ]] || die "$TARGET not found — upstream layout changed, patch needs rebasing"

if grep -q 'DMI_MATCH(DMI_SYS_VENDOR, "GIGABYTE")' "$TARGET"; then
    c_grn "already patched upstream — nothing to do"
elif patch -p1 --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
    patch -p1 < "$PATCH_FILE" >/dev/null
    c_grn "patch applied"
else
    die "patch does not apply cleanly — upstream changed. Rebase patches/0001-*.patch."
fi

grep -q 'DMI_MATCH(DMI_SYS_VENDOR, "GIGABYTE")' "$TARGET" || die "patch verification failed"

# ---------------------------------------------------------------- dkms.conf
step "Preparing DKMS module"
INSTALL_DIR="/usr/src/tuxedo-drivers-$ACTUAL_VERSION"

cat > dkms.conf <<EOF
PACKAGE_NAME="tuxedo-drivers"
PACKAGE_VERSION="$ACTUAL_VERSION"
BUILT_MODULE_NAME[0]="clevo_acpi"
BUILT_MODULE_NAME[1]="clevo_wmi"
BUILT_MODULE_NAME[2]="tuxedo_keyboard"
BUILT_MODULE_NAME[3]="uniwill_wmi"
BUILT_MODULE_LOCATION[0]="src/"
BUILT_MODULE_LOCATION[1]="src/"
BUILT_MODULE_LOCATION[2]="src/"
BUILT_MODULE_LOCATION[3]="src/"
DEST_MODULE_LOCATION[0]="/kernel/drivers/platform/x86"
DEST_MODULE_LOCATION[1]="/kernel/drivers/platform/x86"
DEST_MODULE_LOCATION[2]="/kernel/drivers/platform/x86"
DEST_MODULE_LOCATION[3]="/kernel/drivers/platform/x86"
MAKE="make KDIR=/lib/modules/\${kernelver}/build"
AUTOINSTALL="yes"
EOF

dkms remove -m tuxedo-drivers -v "$ACTUAL_VERSION" --all >/dev/null 2>&1 || true
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -a "$WORKDIR/src/." "$INSTALL_DIR/"

dkms add     -m tuxedo-drivers -v "$ACTUAL_VERSION" >/dev/null
dkms build   -m tuxedo-drivers -v "$ACTUAL_VERSION" >/dev/null
dkms install -m tuxedo-drivers -v "$ACTUAL_VERSION" --force >/dev/null

c_grn "DKMS: $(dkms status tuxedo-drivers | tail -1)"

# ---------------------------------------------------------------- load driver
step "Loading the driver"

for m in clevo_acpi clevo_wmi uniwill_wmi tuxedo_io tuxedo_keyboard tuxedo_compatibility_check; do
    modprobe -r "$m" 2>/dev/null || true
done

# clevo_wmi is the module that pulls in tuxedo_keyboard
modprobe clevo_wmi || die "modprobe clevo_wmi failed — check 'dmesg | tail'"

if [[ ! -e /sys/class/leds/rgb:kbd_backlight ]]; then
    c_red "driver loaded but /sys/class/leds/rgb:kbd_backlight was not created."
    c_red "This can mean the keyboard type reported by the EC is unrecognised."
    c_red "Run 'sudo dmesg | grep -i tuxedo' and open an issue with the output."
    exit 1
fi
c_grn "keyboard backlight LED registered"

# ---------------------------------------------------------------- persistence
step "Installing boot autoload + udev rule + CLI"

install -m 644 "$SCRIPT_DIR/modules-load.d/tuxedo-keyboard.conf" /etc/modules-load.d/
install -m 644 "$SCRIPT_DIR/udev/99-g6-kf-kbd-rgb.rules"        /etc/udev/rules.d/
install -m 755 "$SCRIPT_DIR/scripts/g6rgb"                      /usr/local/bin/g6rgb

udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=leds --sysname-match="rgb:kbd_backlight" 2>/dev/null || true

# ---------------------------------------------------------------- done
step "Done"
c_grn "Your keyboard backlight is now controllable."
echo
echo "  g6rgb blue          # set a colour"
echo "  g6rgb on | off"
echo "  g6rgb status"
echo
echo "If 'g6rgb' needs sudo, add yourself to the video group and re-login:"
echo "  sudo usermod -aG video \$USER"
echo
echo "The backlight resets to white on reboot (driver default). To set your own"
echo "default, see README -> Persisting your colour."
