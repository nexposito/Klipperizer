# ============================================================
#  Klipperizer — Flashing module
#  Flash paths by board state:
#    usb-Katapult_*  → flashtool.py -f <bin> -d <dev>    (direct)
#    usb-Klipper_*   → flashtool.py -r -f <bin> -d <dev> (requests the bootloader)
#    DFU/BOOT        → make flash FLASH_DEVICE=<vid:pid> (first flash)
#    CAN node        → flashtool.py -i can0 -f <bin> -u <uuid>
#  Note: Katapult renamed flash_can.py → flashtool.py; the system
#  automatically detects which of the two exists.
# ============================================================

PYTHON="${KLIPPERIZER_BASE}/.venv/bin/python3"
[ -x "$PYTHON" ] || PYTHON=python3

_flashtool_path() {
  # $1 = katapult dir → path to the flash tool (new or legacy name)
  local katdir="$1"
  if [ -f "$katdir/scripts/flashtool.py" ]; then
    echo "$katdir/scripts/flashtool.py"
  else
    echo "$katdir/scripts/flash_can.py"
  fi
}

query_can_uuid() {
  # $1 = katapult dir → first UUID found on the bus (empty if none)
  local out
  out=$("$PYTHON" "$(_flashtool_path "$1")" -i can0 -q 2>/dev/null || true)
  echo "$out" | awk 'tolower($0) ~ /uuid/ {
    for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-fA-F]{12,}$/) { print tolower($i); exit }
  }'
}

flash_board() {
  local profile="$1" mode="$2" kdir="$3" katdir="$4"
  if [ "$(yq eval '.category' "$profile")" = "adapter" ]; then
    _flash_adapter "$profile"
    return
  fi
  if [ "$mode" = "usb" ]; then
    _flash_usb "$profile" "$mode" "$kdir" "$katdir"
  else
    _flash_can "$profile" "$mode" "$kdir" "$katdir"
  fi
}

_flash_usb() {
  local profile="$1" mode="$2" kdir="$3" katdir="$4"
  local name dev ft
  name=$(yq eval '.name' "$profile")
  ft=$(_flashtool_path "$katdir")

  dev=$(detect_katapult_serial)
  if [ -n "$dev" ]; then
    warn "Katapult detected: $dev — flashing Klipper..."
    "$PYTHON" "$ft" -f "$kdir/out/klipper.bin" -d "$dev" \
      || fatal "Failed to flash via Katapult USB"
    success "Klipper flashed on $name"
    return
  fi

  dev=$(detect_klipper_serial)
  if [ -n "$dev" ]; then
    warn "Running Klipper detected: $dev — requesting bootloader entry..."
    "$PYTHON" "$ft" -r -f "$kdir/out/klipper.bin" -d "$dev" \
      || fatal "Failed to flash via Klipper USB"
    success "Klipper flashed on $name"
    return
  fi

  _first_flash "$profile" "$mode" "$kdir" "$katdir"
}

_flash_can() {
  local profile="$1" mode="$2" kdir="$3" katdir="$4"
  local name uuid ft
  name=$(yq eval '.name' "$profile")
  ft=$(_flashtool_path "$katdir")

  uuid=$(query_can_uuid "$katdir")
  if [ -n "$uuid" ]; then
    warn "CAN node found ($uuid) — flashing Klipper..."
    "$PYTHON" "$ft" -i can0 -f "$kdir/out/klipper.bin" -u "$uuid" \
      || fatal "Failed to flash via CAN"
    success "Klipper flashed on $name"
    return
  fi

  _first_flash "$profile" "$mode" "$kdir" "$katdir"
}

_first_flash() {
  local profile="$1" mode="$2" kdir="$3" katdir="$4"
  local name vids vp uuid t dev ft
  name=$(yq eval '.name' "$profile")
  ft=$(_flashtool_path "$katdir")
  vids=$(yq eval '.bootloader.vid_pid[]' "$profile" 2>/dev/null | tr '\n' ' ')
  [ -n "$vids" ] || fatal "Profile has no bootloader.vid_pid"

  warn "FIRST FLASH — put $name in DFU/BOOT mode now:"
  warn "$(yq eval '.bootloader.instructions' "$profile")"
  vp=$(wait_for_dfu "$vids" 300) \
    || fatal "No DFU/BOOT device ($vids) detected within 5 minutes."
  success "Device detected: $vp"

  warn "Flashing Katapult via DFU/BOOT..."
  make -C "$katdir" flash FLASH_DEVICE="$vp" >/dev/null \
    || fatal "Failed to flash Katapult"

  warn "Waiting for the board to re-enumerate..."
  if [ "$mode" = "usb" ]; then
    dev=$(wait_for_serial 60) || fatal "Board did not reappear after the Katapult flash."
    warn "Flashing Klipper via Katapult USB ($dev)..."
    "$PYTHON" "$ft" -f "$kdir/out/klipper.bin" -d "$dev" \
      || fatal "Failed to flash Klipper via USB"
  else
    uuid=""; t=0
    while [ -z "$uuid" ] && [ "$t" -lt 90 ]; do
      uuid=$(query_can_uuid "$katdir")
      [ -n "$uuid" ] || { sleep 2; t=$((t + 2)); }
    done
    [ -n "$uuid" ] || fatal "CAN node did not show up. Check can0 (ip link show can0) and the H/L wiring."
    warn "Flashing Klipper via Katapult CAN ($uuid)..."
    "$PYTHON" "$ft" -i can0 -f "$kdir/out/klipper.bin" -u "$uuid" \
      || fatal "Failed to flash Klipper via CAN"
  fi
  success "First flash complete: $name running Klipper!"
}

_flash_adapter() {
  # USB-CAN adapters (U2C, UTOC) do not run Katapult/Klipper:
  # they receive a binary directly via dfu-util, as defined in the profile.
  local profile="$1" url cmd file vids vp
  url=$(yq eval '.adapter.firmware' "$profile")
  cmd=$(yq eval '.adapter.command' "$profile")
  vids=$(yq eval '.bootloader.vid_pid[]' "$profile" 2>/dev/null | tr '\n' ' ')
  [ -n "$url" ] && [ "$url" != "null" ] || fatal "Adapter profile has no 'adapter.firmware'"
  [ -n "$cmd" ] && [ "$cmd" != "null" ] || fatal "Adapter profile has no 'adapter.command' — set it after choosing the firmware"

  mkdir -p "$KLIPPERIZER_BASE/out"
  file="$KLIPPERIZER_BASE/out/$(basename "$url")"
  warn "Downloading adapter firmware..."
  wget -qO "$file" "$url" || fatal "Firmware download failed"

  warn "Put the adapter in DFU mode now:"
  warn "$(yq eval '.bootloader.instructions' "$profile")"
  vp=$(wait_for_dfu "$vids" 300) || fatal "DFU not detected ($vids)."
  success "Device detected: $vp — flashing..."

  cmd="${cmd//\\{vidpid\\}/$vp}"
  cmd="${cmd//\\{file\\}/$file}"
  bash -c "$cmd" || fatal "Failed to flash the adapter"
  success "Adapter flashed!"
}
