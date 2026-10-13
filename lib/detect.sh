# ============================================================
#  Klipperizer — Detecção de dispositivos
#  Estados possíveis de uma placa:
#    DFU/BOOT     → lsusb (ex.: 0483:df11, 2e8a:0003, 314b:0106)
#    Katapult USB → /dev/serial/by-id/usb-Katapult_*
#    Klipper USB  → /dev/serial/by-id/usb-Klipper_*
# ============================================================

# Aguarda um dispositivo DFU/BOOT aparecer. $1 = lista de VID:PID, $2 = timeout (s)
esperar_dfu() {
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

detectar_serial_katapult() {
  ls /dev/serial/by-id/usb-Katapult_* 2>/dev/null | head -1 || true
}

detectar_serial_klipper() {
  ls /dev/serial/by-id/usb-Klipper_* 2>/dev/null | head -1 || true
}

# Aguarda qualquer serial (Katapult ou Klipper) aparecer. $1 = timeout (s)
esperar_serial() {
  local timeout="${1:-60}" t=0 d
  while [ "$t" -lt "$timeout" ]; do
    d=$(detectar_serial_katapult)
    [ -z "$d" ] && d=$(detectar_serial_klipper)
    if [ -n "$d" ]; then
      echo "$d"
      return 0
    fi
    sleep 1
    t=$((t + 1))
  done
  return 1
}
