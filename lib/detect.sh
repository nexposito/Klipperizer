# ============================================================
#  Klipperizer — Device detection
#  Possible board states:
#    DFU/BOOT     → lsusb (e.g. 0483:df11, 2e8a:0003, 314b:0106)
#    Katapult USB → /dev/serial/by-id/usb-Katapult_*
#    Klipper USB  → /dev/serial/by-id/usb-Klipper_*
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

detect_katapult_serial() {
  ls /dev/serial/by-id/usb-Katapult_* 2>/dev/null | head -1 || true
}

detect_klipper_serial() {
  ls /dev/serial/by-id/usb-Klipper_* 2>/dev/null | head -1 || true
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
