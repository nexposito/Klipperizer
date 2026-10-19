#!/usr/bin/env bash
# ============================================================
#  Klipperizer — Installer
#  Usage: bash install.sh
#  Installs dependencies, clones Klipper and Katapult, sets up
#  udev rules, the CAN interface (can0), the executable bit and
#  the global command.
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
# The rules must cover BOTH device states: DFU/BOOT (lsusb VID:PID) and
# the serial firmware modes — Katapult/Klipper enumerate as USB CDC with
# different VID:PID (e.g. 0483:5740 on STM32). Without the serial rules
# the flash fails with 'Permission denied' (Errno 13).
log "Installing udev rules..."
sudo tee /etc/udev/rules.d/99-klipperizer.rules >/dev/null <<'EOF'
# Klipperizer — USB access rules for flashing without sudo
# DFU/BOOT device modes
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0003", MODE="0666"
SUBSYSTEM=="usb", ATTRS{idVendor}=="314b", ATTRS{idProduct}=="0106", MODE="0666"
# STM32 USB CDC serial (Katapult/Klipper firmware running)
SUBSYSTEM=="tty", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="5740", MODE="0666"
# RP2040 USB serial (Katapult/Klipper firmware running)
SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", MODE="0666"
# Generic fallback for the dedicated flashing host: any USB serial device
SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", MODE="0666"
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", MODE="0666"
EOF
# Belt-and-suspenders: dialout group membership (covers hosts where other
# packages override the MODE rules). Effective on next login.
if ! id -nG "$USER" 2>/dev/null | grep -qw dialout; then
  log "Adding $USER to the dialout group (effective on next login)..."
  sudo usermod -aG dialout "$USER" || true
fi
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

# ---------- 7. CAN interface (can0) — Esoterical guide method ----------
# Follows the CURRENT Esoterical CANBus guide: systemd-networkd manages
# the can* interfaces (ifupdown/interfaces.d is being phased out), a udev
# rule sets txqueuelen=128 (Klipper docs recommendation) and a .network
# file sets the bus speed to 1 Mbit. An existing 25-can.network is kept.
sudo modprobe gs_usb 2>/dev/null || true   # driver for USB-CAN adapters

if command -v systemctl >/dev/null 2>&1; then
  log "Enabling systemd-networkd (manages the CAN interfaces)..."
  sudo systemctl unmask systemd-networkd 2>/dev/null || true
  sudo systemctl enable systemd-networkd
  sudo systemctl start systemd-networkd \
    || log "Warning: systemd-networkd did not start — check 'systemctl status systemd-networkd'."
  # wait-online can freeze the boot for ~2 min waiting for CAN — disable it
  sudo systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

  log "Creating the CAN udev rule (txqueuelen 128)..."
  echo -e 'SUBSYSTEM=="net", ACTION=="change|add", KERNEL=="can*"  ATTR{tx_queue_len}="128"' \
    | sudo tee /etc/udev/rules.d/10-can.rules >/dev/null

  if sudo test -f /etc/systemd/network/25-can.network; then
    log "CAN network config already exists (/etc/systemd/network/25-can.network) — keeping it."
  else
    log "Creating CAN network config (/etc/systemd/network/25-can.network, 1 Mbit)..."
    echo -e "[Match] \n Name=can* \n\n [CAN] \n BitRate=1M \n\n [Link] \n RequiredForOnline=no" \
      | sudo tee /etc/systemd/network/25-can.network >/dev/null
  fi
  sudo udevadm control --reload-rules 2>/dev/null || true

  if ip link show can0 >/dev/null 2>&1; then
    log "CAN adapter detected — bringing can0 up at 1 Mbit..."
    sudo ip link set can0 down 2>/dev/null || true
    sudo ip link set can0 type can bitrate 1000000
    sudo ip link set can0 txqueuelen 128
    sudo ip link set can0 up
    ip -details link show can0 | sed 's/^/  /' || true
  else
    log "No CAN adapter plugged in yet — can0 will come up automatically when you connect it."
    log "A reboot is recommended so systemd-networkd reads the new config files."
  fi
else
  log "systemctl not available — skipping the CAN interface setup."
fi

# ---------- 8. Global command ----------
sudo ln -sf "$BASEDIR/klipperizer" /usr/local/bin/klipperizer

log "Installation complete!"
log "Run './klipperizer' from this folder to open the menu — Klipper and Katapult are ready."
log "If the global 'klipperizer' command fails, './klipperizer' always works."
