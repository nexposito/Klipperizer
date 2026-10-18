# ============================================================
#  Klipperizer — Flashing module
#  Flash paths by board state:
#    usb-Katapult_*  → flashtool.py -f <bin> -d <dev>    (direct)
#    usb-Klipper_*   → flashtool.py -r -f <bin> -d <dev> (requests the bootloader)
#    DFU/BOOT (STM32)→ dfu-util -R -a 0 -s 0x08000000:mass-erase:force:leave
#    DFU/BOOT (other)→ make flash FLASH_DEVICE=<vid:pid>
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

_check_modemmanager() {
  # ModemManager probes new USB devices and can hijack a DFU session
  # mid-flash ('Error during download get_status'). Warn before flashing.
  if command -v systemctl >/dev/null 2>&1 && \
     systemctl is-active ModemManager >/dev/null 2>&1; then
    warn "ModemManager is active — it can hijack DFU flashing and cause 'Error during download get_status'."
    warn "Disable it now with: sudo systemctl stop ModemManager"
  fi
}

_dfu_flash_stm32() {
  # $1 = katapult dir | $2 = vid:pid
  # Esoterical guide command for STM32 DFU: mass-erase wipes the whole flash
  # before the download and 'force' overrides erase-capability quirks of some
  # STM32 DFU bootloaders — more robust than the plain 'make flash' wrapper.
  local katdir="$1" vp="$2"
  if dfu-util -R -a 0 -s 0x08000000:mass-erase:force:leave \
       -D "$katdir/out/katapult.bin" -d "$vp"; then
    return 0
  fi
  warn "dfu-util failed without sudo — retrying with sudo (udev permissions may be missing)..."
  sudo dfu-util -R -a 0 -s 0x08000000:mass-erase:force:leave \
    -D "$katdir/out/katapult.bin" -d "$vp"
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
  local name vids vp uuid t dev ft method
  name=$(yq eval '.name' "$profile")
  ft=$(_flashtool_path "$katdir")
  method=$(yq eval '.bootloader.method' "$profile")
  vids=$(yq eval '.bootloader.vid_pid[]' "$profile" 2>/dev/null | tr '\n' ' ')
  [ -n "$vids" ] || fatal "Profile has no bootloader.vid_pid"

  _check_modemmanager

  warn "FIRST FLASH — put $name in DFU/BOOT mode now:"
  warn "$(yq eval '.bootloader.instructions' "$profile")"
  vp=$(wait_for_dfu "$vids" 300) \
    || fatal "No DFU/BOOT device ($vids) detected within 5 minutes."
  success "Device detected: $vp"

  warn "Flashing Katapult via DFU/BOOT..."
  if [ "$method" = "dfu" ]; then
    _dfu_flash_stm32 "$katdir" "$vp" \
      || fatal "Failed to flash Katapult via DFU. Power cycle the board (unplug USB, wait 5s, redo the BOOT sequence) and run again. If it keeps failing: 'sudo systemctl stop ModemManager', another USB cable, or connect directly to the host (no hub)."
  else
    make -C "$katdir" flash FLASH_DEVICE="$vp" >/dev/null \
      || fatal "Failed to flash Katapult via BOOT. Power cycle the board (unplug USB, wait 5s, redo the BOOT sequence) and run again."
  fi

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

  _check_modemmanager

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
  bash -c "$cmd" \
    || fatal "Failed to flash the adapter. Power cycle it (unplug USB, redo the BOOT sequence) and run again. If it keeps failing: 'sudo systemctl stop ModemManager'."
  success "Adapter flashed!"
}
