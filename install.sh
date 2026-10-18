#!/usr/bin/env bash
# ============================================================
#  Klipperizer — Installer
#  Usage: bash install.sh
#  Installs dependencies, clones Klipper and Katapult, sets up
#  udev rules, the executable bit and the global command.
# ============================================================
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\033[1;34m[Klipperizer]\033[0m $*"; }
fail() { echo -e "\033[1;31m[Error]\033[0m $*" >&2; exit 1; }

# ---------- 1. System dependencies ----------
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf >/dev/null; then PKG=dnf
elif command -v pacman >/dev/null; then PKG=pacman
else fail "Unsupported distribution (apt/dnf/pacman)."
fi

log "Installing system dependencies (will ask for sudo)..."
case $PKG in
  apt)
    sudo apt-get update -qq
    sudo apt-get install -y git build-essential python3 python3-venv python3-pip \
      dfu-util can-utils iproute2 whiptail wget curl gcc-arm-none-eabi
    ;;
  dnf)
    sudo dnf install -y git gcc make python3 python3-pip dfu-util can-utils \
      iproute2 newt wget curl arm-none-eabi-gcc-cs arm-none-eabi-newlib-cs
    ;;
  pacman)
    sudo pacman -Sy --needed git base-devel python python-pip dfu-util can-utils \
      iproute2 libnewt wget curl arm-none-eabi-gcc arm-none-eabi-newlib
    ;;
esac

# The ARM cross-compiler is mandatory: Klipper and Katapult firmware for
# STM32/RP2040 cannot build with the native gcc alone
command -v arm-none-eabi-gcc >/dev/null 2>&1 \
  || fail "ARM cross-compiler (arm-none-eabi-gcc) not found — install it manually and re-run install.sh"

# yq — processes the board profile YAML files
if ! command -v yq >/dev/null 2>&1; then
  log "Installing yq..."
  case $(uname -m) in
    x86_64)        YQ_ARCH=amd64 ;;
    aarch64|arm64) YQ_ARCH=arm64 ;;
    armv7*|armv6*) YQ_ARCH=arm   ;;
    *) fail "Unsupported architecture for yq: $(uname -m)" ;;
  esac
  sudo wget -qO /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"
  sudo chmod +x /usr/local/bin/yq
fi

# ---------- 2. Python environment (flash tools) ----------
log "Creating Python environment..."
python3 -m venv "$BASEDIR/.venv"
"$BASEDIR/.venv/bin/pip" install --quiet --upgrade pip
"$BASEDIR/.venv/bin/pip" install --quiet python-can pyserial

# ---------- 3. Klipper and Katapult (clone or update) ----------
log "Preparing Klipper (may take a while)..."
if [ -d "$BASEDIR/klipper/.git" ]; then
  git -C "$BASEDIR/klipper" pull --ff-only \
    || log "Warning: could not update Klipper — keeping the current version."
else
  git clone --depth 1 https://github.com/Klipper3d/klipper "$BASEDIR/klipper"
fi

log "Preparing Katapult..."
if [ -d "$BASEDIR/katapult/.git" ]; then
  git -C "$BASEDIR/katapult" pull --ff-only \
    || log "Warning: could not update Katapult — keeping the current version."
else
  git clone --depth 1 https://github.com/Arksine/katapult "$BASEDIR/katapult"
fi

# ---------- 4. Executable permissions ----------
# Files coming from sync services (Drive/GitHub Desktop) may lose the +x bit
chmod +x "$BASEDIR/klipperizer" "$BASEDIR"/lib/*.sh \
  "$BASEDIR/install.sh" "$BASEDIR/uninstall.sh" 2>/dev/null || true

# ---------- 5. udev rules (flash without sudo) ----------
log "Installing udev rules..."
sudo cp "$BASEDIR/udev/99-klipperizer.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger

# ---------- 6. ModemManager (breaks DFU/serial flashing) ----------
# ModemManager probes every new USB device and can hijack a DFU session
# mid-flash, causing 'Error during download get_status'. Same reason KIAUH
# offers to disable it. Re-enable later with:
#   sudo systemctl enable --now ModemManager
if command -v systemctl >/dev/null 2>&1 && \
   systemctl is-active ModemManager >/dev/null 2>&1; then
  log "Disabling ModemManager (it probes new USB devices and breaks DFU flashing)..."
  sudo systemctl stop ModemManager
  sudo systemctl disable ModemManager
fi

# ---------- 7. Global command ----------
sudo ln -sf "$BASEDIR/klipperizer" /usr/local/bin/klipperizer

log "Installation complete!"
log "Run './klipperizer' from this folder to open the menu — Klipper and Katapult are ready."
log "If the global 'klipperizer' command fails, './klipperizer' always works."
