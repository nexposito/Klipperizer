# ============================================================
#  Klipperizer — Device detection
#  Possible board states:
#    DFU/BOOT     → lsusb (e.g. 0483:df11, 2e8a:0003, 314b:0106)
#    Katapult USB → /dev/serial/by-id/usb-Katapult_* (legacy: usb-CanBoot_*)
#    Klipper USB  → /dev/serial/by-id/usb-Klipper_*
#  Serial matching scans ALL /dev/serial/by-id/* entries: the symlink
#  name first (usb-Katapult_*, usb-CanBoot_*, usb-Klipper_*) and, when
#  the name does not match, the real USB identity via udevadm — this
#  catches bootloaders flashed with custom manufacturer strings.
# ============================================================

# Waits for a DFU/BOOT device to show up. $1 = VID:PID list, $2 = timeout (s)
wait_for_dfu() {
  local vids="$1" timeout="${2:-180}" t=0 vp
  while [ "$t" -lt "$timeout" ]; do
    for vp in $vids; do
      if lsusb -d "$vp" 2>/dev/null | grep -q .; then
        echo "$vp"
        return 0
      fi
    done
    sleep 1
    t=$((t + 1))
  done
  return 1
}

_serial_is_katapult() {
  # $1 = /dev/serial/by-id path → true if the USB identity is Katapult/CanBoot
  local base props
  base=$(basename "$1")
  case "$base" in
    usb-Katapult_*|usb-CanBoot_*) return 0 ;;
  esac
  # Custom USB strings: ask udev for the real product/manufacturer identity
  command -v udevadm >/dev/null 2>&1 || return 1
  props=$(udevadm info -q property -n "$1" 2>/dev/null || true)
  printf '%s\n' "$props" | grep -qiE '^(ID_MODEL|ID_VENDOR)=(katapult|canboot)'
}

_serial_is_klipper() {
  # $1 = /dev/serial/by-id path → true if the USB identity is Klipper
  local base props
  base=$(basename "$1")
  case "$base" in
    usb-Klipper_*) return 0 ;;
  esac
  command -v udevadm >/dev/null 2>&1 || return 1
  props=$(udevadm info -q property -n "$1" 2>/dev/null || true)
  printf '%s\n' "$props" | grep -qiE '^ID_MODEL=klipper'
}

detect_katapult_serial() {
  # First Katapult/CanBoot serial device (empty output = none found)
  local d
  for d in /dev/serial/by-id/*; do
    [ -e "$d" ] || continue
    if _serial_is_katapult "$d"; then
      echo "$d"
      return 0
    fi
  done
  return 0
}

detect_klipper_serial() {
  # First Klipper serial device (empty output = none found)
  local d
  for d in /dev/serial/by-id/*; do
    [ -e "$d" ] || continue
    if _serial_is_klipper "$d"; then
      echo "$d"
      return 0
    fi
  done
  return 0
}

# Waits for any serial (Katapult or Klipper) to show up. $1 = timeout (s)
wait_for_serial() {
  local timeout="${1:-60}" t=0 d
  while [ "$t" -lt "$timeout" ]; do
    d=$(detect_katapult_serial)
    [ -z "$d" ] && d=$(detect_klipper_serial)
    if [ -n "$d" ]; then
      echo "$d"
      return 0
    fi
    sleep 1
    t=$((t + 1))
  done
  return 1
}
