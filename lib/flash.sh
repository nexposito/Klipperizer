# ============================================================
#  Klipperizer — Flashing module
#  Flash paths by board state:
#    usb-Katapult_*  → flashtool.py -f <bin> -d <dev>    (direct)
#    usb-Klipper_*   → flashtool.py -r -f <bin> -d <dev> (requests the bootloader)
#    DFU/BOOT (STM32)→ dfu-util -R -a 0 -s 0x08000000:mass-erase:force:leave
#    DFU/BOOT (other)→ make flash FLASH_DEVICE=<vid:pid>
#    CAN node        → flashtool.py -i can0 -f <bin> -u <uuid>
#
#  PRE-CHECK: before any Katapult flash, the tool tests whether
#  Katapult is already installed — via USB serial (/dev/serial/by-id/*
#  scan, name or udev identity) or via the CAN bus (UUID query, only
#  if can0 exists). If found, the Katapult flash is skipped.
#
#  First flash (no Katapult found) runs as 4 explicit steps:
#    1. Board enters DFU/BOOT (shows the USB address) — the wait ALSO
#       watches /dev/serial/by-id/* for an already-installed Katapult
#       and skips the Katapult flash the moment it appears
#    2. Katapult flash (explicit success/failure)
#    3. Board re-enumeration — USB: serial device; CAN: cable swap
#       message (disconnect USB, connect CAN-H/CAN-L) + ENTER
#       confirmation before polling the bus for the UUID
#    4. Klipper flash (only if step 2 succeeded)
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
  #
  # IMPORTANT: 'Error during download get_status' printed AFTER
  # 'Submitting leave request' is BENIGN — the board resets and disconnects
  # before dfu-util can read the final status response. If the download
  # itself completed ('Download done' / 'File downloaded successfully'),
  # the firmware IS on the board and the flow must continue.
  local katdir="$1" vp="$2" tmpf
  tmpf=$(mktemp)

  dfu-util -R -a 0 -s 0x08000000:mass-erase:force:leave \
    -D "$katdir/out/katapult.bin" -d "$vp" 2>&1 | tee "$tmpf" | sed 's/^/  /' || true

  if grep -qE 'Download[[:space:]]+done|File downloaded successfully' "$tmpf"; then
    if grep -q 'Error during download get_status' "$tmpf"; then
      warn "dfu-util status error after the download — benign: the board already reset into Katapult."
    fi
    rm -f "$tmpf"
    return 0
  fi

  warn "dfu-util failed without sudo — retrying with sudo (udev permissions may be missing)..."
  sudo dfu-util -R -a 0 -s 0x08000000:mass-erase:force:leave \
    -D "$katdir/out/katapult.bin" -d "$vp" 2>&1 | tee "$tmpf" | sed 's/^/  /' || true

  if grep -qE 'Download[[:space:]]+done|File downloaded successfully' "$tmpf"; then
    rm -f "$tmpf"
    return 0
  fi
  rm -f "$tmpf"
  return 1
}

query_can_uuid() {
  # $1 = katapult dir → first UUID found on the bus (empty if none)
  local out
  out=$("$PYTHON" "$(_flashtool_path "$1")" -i can0 -q 2>/dev/null || true)
  echo "$out" | awk 'tolower($0) ~ /uuid/ {
    for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-fA-F]{12,}$/) { print tolower($i); exit }
  }'
}

_wait_enter() {
  # $1 = message → waits for ENTER before continuing.
  # If stdin is not a terminal (scripted runs), falls back to a short delay
  # so the flow never hangs waiting for input that will never come.
  local msg="$1"
  if [ -t 0 ]; then
    printf "%s" "$msg"
    read -r || sleep 5
  else
    warn "Non-interactive session — waiting 5s before continuing..."
    sleep 5
  fi
}

_wait_can_node() {
  # Polls the bus for a CAN node UUID (up to 90s). Prints the UUID when found.
  local katdir="$1" uuid="" t=0
  while [ -z "$uuid" ] && [ "$t" -lt 90 ]; do
    uuid=$(query_can_uuid "$katdir")
    [ -n "$uuid" ] || { sleep 2; t=$((t + 2)); }
  done
  if [ -n "$uuid" ]; then
    success "Board detected on CAN — UUID: $uuid"
    warn "Add this UUID to your printer.cfg [mcu] section:"
    warn "  canbus_uuid: $uuid"
  fi
  echo "$uuid"
}

_switch_to_can_prompt() {
  # Cable swap instructions + ENTER confirmation (shared by the CAN paths)
  warn "Switch the board to CAN now:"
  warn "  1. Disconnect the USB cable"
  warn "  2. Connect CAN-H and CAN-L to the bus"
  warn "  3. If the board was powered only via USB, connect the 24V/CAN power now"
  _wait_enter $'\n  Press ENTER when the CAN cables are connected... '
  warn "Searching for the CAN node on the bus..."
}

_wait_dfu_or_katapult() {
  # $1 = VID:PID list | $2 = timeout (s)
  # Watches DFU (lsusb) and Katapult serial (/dev/serial/by-id/*) at the
  # same time; echoes "dfu <vid:pid>" or "katapult <serial>" for whichever
  # appears first. A board that already runs Katapult never enters DFU,
  # so watching both is what makes the skip possible.
  local vids="$1" timeout="${2:-300}" t=0 vp dev
  while [ "$t" -lt "$timeout" ]; do
    dev=$(detect_katapult_serial)
    if [ -n "$dev" ]; then
      echo "katapult $dev"
      return 0
    fi
    for vp in $vids; do
      if lsusb -d "$vp" 2>/dev/null | grep -q .; then
        echo "dfu $vp"
        return 0
      fi
    done
    sleep 1
    t=$((t + 1))
  done
  return 1
}

flash_board() {
  local profile="$1" mode="$2" kdir="$3" katdir="$4"
  local name ft dev uuid
  name=$(yq eval '.name' "$profile")
  ft=$(_flashtool_path "$katdir")

  if [ "$(yq eval '.category' "$profile")" = "adapter" ]; then
    _flash_adapter "$profile"
    return
  fi

  # ---- PRE-CHECK: is Katapult already installed? ----
  warn "Checking if Katapult is already installed on $name..."

  # 1) Katapult on USB serial? (scans /dev/serial/by-id/*)
  dev=$(detect_katapult_serial)
  if [ -n "$dev" ]; then
    success "Katapult already installed (detected via USB: $dev) — skipping the Katapult flash."
    warn "Flashing the $mode-configured Klipper via Katapult USB..."
    "$PYTHON" "$ft" -f "$kdir/out/klipper.bin" -d "$dev" \
      || fatal "Failed to flash Klipper via Katapult USB"
    success "Klipper flashed successfully!"
    if [ "$mode" = "can" ]; then
      warn "Waiting 3s for the board to reset..."
      sleep 3
      _switch_to_can_prompt
      uuid=$(_wait_can_node "$katdir")
      [ -n "$uuid" ] || fatal "CAN node did not show up. Check can0 (ip link show can0), the H/L wiring (H→H, L→L) and the 120R jumper."
      success "Board is ready on CAN!"
    fi
    return
  fi

  # 2) Katapult on the CAN bus? (only if can0 exists)
  if ip link show can0 >/dev/null 2>&1; then
    uuid=$(query_can_uuid "$katdir")
    if [ -n "$uuid" ]; then
      success "Katapult already installed (detected via CAN: $uuid) — skipping the Katapult flash."
      warn "Flashing the $mode-configured Klipper via CAN..."
      "$PYTHON" "$ft" -i can0 -f "$kdir/out/klipper.bin" -u "$uuid" \
        || fatal "Failed to flash Klipper via CAN"
      success "Klipper flashed successfully!"
      warn "Add this UUID to your printer.cfg [mcu] section:"
      warn "  canbus_uuid: $uuid"
      return
    fi
  fi

  warn "No Katapult detected — proceeding with the first flash (DFU/BOOT)."

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

  # Fallback re-check: Katapult may have appeared since the pre-check
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

  # Fallback re-check: a CAN node may have appeared since the pre-check
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
  local name vids vp uuid t dev ft method state
  name=$(yq eval '.name' "$profile")
  ft=$(_flashtool_path "$katdir")
  method=$(yq eval '.bootloader.method' "$profile")
  vids=$(yq eval '.bootloader.vid_pid[]' "$profile" 2>/dev/null | tr '\n' ' ')
  [ -n "$vids" ] || fatal "Profile has no bootloader.vid_pid"

  _check_modemmanager

  # ---- STEP 1: board enters DFU/BOOT — or Katapult is already there ----
  warn "STEP 1/4 — put $name in DFU/BOOT mode now:"
  warn "$(yq eval '.bootloader.instructions' "$profile")"
  warn "  (If the board already runs Katapult, it will be detected automatically)"
  state=$(_wait_dfu_or_katapult "$vids" 300) \
    || fatal "No DFU/BOOT device ($vids) detected within 5 minutes."

  if [ "${state%% *}" = "katapult" ]; then
    dev="${state#* }"
    success "Katapult already installed (detected via USB: $dev) — skipping the Katapult flash."
    warn "Flashing the $mode-configured Klipper via Katapult USB..."
    "$PYTHON" "$ft" -f "$kdir/out/klipper.bin" -d "$dev" \
      || fatal "Klipper flash FAILED via USB."
    success "Klipper flashed successfully!"
    if [ "$mode" = "can" ]; then
      warn "Waiting 3s for the board to reset..."
      sleep 3
      _switch_to_can_prompt
      uuid=$(_wait_can_node "$katdir")
      [ -n "$uuid" ] || fatal "CAN node did not show up. Check can0 (ip link show can0), the H/L wiring (H→H, L→L) and the 120R jumper."
      success "Board is ready on CAN!"
    else
      success "$name is running Klipper!"
    fi
    return
  fi

  vp="${state#* }"
  success "Board entered DFU mode — USB address: $vp"
  lsusb -d "$vp" 2>/dev/null | head -1 | sed 's/^/  /' || true
  sleep 2   # let the USB device settle before claiming it

  # ---- STEP 2: flash Katapult ----
  warn "STEP 2/4 — Flashing Katapult..."
  if [ "$method" = "dfu" ]; then
    _dfu_flash_stm32 "$katdir" "$vp" \
      || fatal "Katapult flash FAILED. Power cycle the board (unplug USB, wait 5s, redo the BOOT sequence) and run again. If it keeps failing: 'sudo systemctl stop ModemManager', another USB cable, or connect directly to the host (no hub)."
  else
    make -C "$katdir" flash FLASH_DEVICE="$vp" >/dev/null \
      || fatal "Katapult flash FAILED. Power cycle the board (unplug USB, wait 5s, redo the BOOT sequence) and run again."
  fi
  success "Katapult flashed successfully!"
  warn "Waiting 3s for the board to reset..."
  sleep 3

  # ---- STEP 3: board re-enumeration ----
  if [ "$mode" = "usb" ]; then
    warn "STEP 3/4 — Waiting for the board to re-enumerate on USB..."
    dev=$(wait_for_serial 60) \
      || fatal "Board did not reappear after the Katapult flash."
    success "Board detected on USB: $dev"
  else
    warn "STEP 3/4 — Switch the board to CAN now:"
    _switch_to_can_prompt
    uuid=$(_wait_can_node "$katdir")
    [ -n "$uuid" ] || fatal "CAN node did not show up. Check can0 (ip link show can0), the H/L wiring (H→H, L→L) and the 120R jumper."
  fi
  sleep 1

  # ---- STEP 4: flash Klipper ----
  warn "STEP 4/4 — Flashing Klipper..."
  if [ "$mode" = "usb" ]; then
    "$PYTHON" "$ft" -f "$kdir/out/klipper.bin" -d "$dev" \
      || fatal "Klipper flash FAILED via USB."
  else
    "$PYTHON" "$ft" -i can0 -f "$kdir/out/klipper.bin" -u "$uuid" \
      || fatal "Klipper flash FAILED via CAN."
  fi
  success "Klipper flashed successfully!"
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
  sleep 2

  cmd="${cmd//\\{vidpid\\}/$vp}"
  cmd="${cmd//\\{file\\}/$file}"
  bash -c "$cmd" \
    || fatal "Failed to flash the adapter. Power cycle it (unplug USB, redo the BOOT sequence) and run again. If it keeps failing: 'sudo systemctl stop ModemManager'."
  success "Adapter flashed!"
}
