# ============================================================
#  Klipperizer — Módulo de gravação
#  Caminhos de flash por estado da placa:
#    usb-Katapult_*  → flashtool.py -f <bin> -d <dev>   (direto)
#    usb-Klipper_*   → flashtool.py -r -f <bin> -d <dev> (pede o bootloader)
#    DFU/BOOT        → make flash FLASH_DEVICE=<vid:pid> (1º flash)
#    nó CAN          → flashtool.py -i can0 -f <bin> -u <uuid>
#  Nota: o Katapult renomeou flash_can.py → flashtool.py; o
#  sistema detecta automaticamente qual dos dois existe.
# ============================================================

PYTHON="${KLIPPERIZER_BASE}/.venv/bin/python3"
[ -x "$PYTHON" ] || PYTHON=python3

_flashtool() {
  # $1 = katapult dir → caminho do flashtool (novo ou legado)
  local katdir="$1"
  if [ -f "$katdir/scripts/flashtool.py" ]; then
    echo "$katdir/scripts/flashtool.py"
  else
    echo "$katdir/scripts/flash_can.py"
  fi
}

consultar_uuid_can() {
  # $1 = katapult dir → 1º UUID encontrado no barramento (vazio se nenhum)
  local out
  out=$("$PYTHON" "$(_flashtool "$1")" -i can0 -q 2>/dev/null || true)
  echo "$out" | awk 'tolower($0) ~ /uuid/ {
    for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-fA-F]{12,}$/) { print tolower($i); exit }
  }'
}

flashear() {
  local perfil="$1" modo="$2" kdir="$3" katdir="$4"
  if [ "$(yq eval '.categoria' "$perfil")" = "adaptador" ]; then
    _flash_adaptador "$perfil"
    return
  fi
  if [ "$modo" = "usb" ]; then
    _flash_usb "$perfil" "$modo" "$kdir" "$katdir"
  else
    _flash_can "$perfil" "$modo" "$kdir" "$katdir"
  fi
}

_flash_usb() {
  local perfil="$1" modo="$2" kdir="$3" katdir="$4"
  local nome dev ft
  nome=$(yq eval '.nome' "$perfil")
  ft=$(_flashtool "$katdir")

  dev=$(detectar_serial_katapult)
  if [ -n "$dev" ]; then
    aviso "Katapult detectado: $dev — gravando Klipper..."
    "$PYTHON" "$ft" -f "$kdir/out/klipper.bin" -d "$dev" \
      || erro_fatal "Falha ao gravar via Katapult USB"
    sucesso "Klipper gravado em $nome"
    return
  fi

  dev=$(detectar_serial_klipper)
  if [ -n "$dev" ]; then
    aviso "Klipper em execução detectado: $dev — pedindo entrada no bootloader..."
    "$PYTHON" "$ft" -r -f "$kdir/out/klipper.bin" -d "$dev" \
      || erro_fatal "Falha ao gravar via Klipper USB"
    sucesso "Klipper gravado em $nome"
    return
  fi

  _primeiro_flash "$perfil" "$modo" "$kdir" "$katdir"
}

_flash_can() {
  local perfil="$1" modo="$2" kdir="$3" katdir="$4"
  local nome uuid ft
  nome=$(yq eval '.nome' "$perfil")
  ft=$(_flashtool "$katdir")

  uuid=$(consultar_uuid_can "$katdir")
  if [ -n "$uuid" ]; then
    aviso "Nó CAN encontrado ($uuid) — gravando Klipper..."
    "$PYTHON" "$ft" -i can0 -f "$kdir/out/klipper.bin" -u "$uuid" \
      || erro_fatal "Falha ao gravar via CAN"
    sucesso "Klipper gravado em $nome"
    return
  fi

  _primeiro_flash "$perfil" "$modo" "$kdir" "$katdir"
}

_primeiro_flash() {
  local perfil="$1" modo="$2" kdir="$3" katdir="$4"
  local nome vids vp uuid t dev ft
  nome=$(yq eval '.nome' "$perfil")
  ft=$(_flashtool "$katdir")
  vids=$(yq eval '.bootloader.vid_pid[]' "$perfil" 2>/dev/null | tr '\n' ' ')
  [ -n "$vids" ] || erro_fatal "Perfil sem bootloader.vid_pid"

  aviso "PRIMEIRO FLASH — coloque $nome em modo DFU/BOOT agora:"
  aviso "$(yq eval '.bootloader.instrucoes' "$perfil")"
  vp=$(esperar_dfu "$vids" 300) \
    || erro_fatal "Nenhum dispositivo DFU/BOOT ($vids) detectado em 5 minutos."
  sucesso "Dispositivo detectado: $vp"

  aviso "Gravando Katapult via DFU/BOOT..."
  make -C "$katdir" flash FLASH_DEVICE="$vp" >/dev/null \
    || erro_fatal "Falha ao gravar o Katapult"

  aviso "Aguardando a placa re-enumerar..."
  if [ "$modo" = "usb" ]; then
    dev=$(esperar_serial 60) || erro_fatal "Placa não reapareceu após o flash do Katapult."
    aviso "Gravando Klipper via Katapult USB ($dev)..."
    "$PYTHON" "$ft" -f "$kdir/out/klipper.bin" -d "$dev" \
      || erro_fatal "Falha ao gravar o Klipper via USB"
  else
    uuid=""; t=0
    while [ -z "$uuid" ] && [ "$t" -lt 90 ]; do
      uuid=$(consultar_uuid_can "$katdir")
      [ -n "$uuid" ] || { sleep 2; t=$((t + 2)); }
    done
    [ -n "$uuid" ] || erro_fatal "Nó CAN não apareceu. Verifique can0 (ip link show can0) e a fiação H/L."
    aviso "Gravando Klipper via Katapult CAN ($uuid)..."
    "$PYTHON" "$ft" -i can0 -f "$kdir/out/klipper.bin" -u "$uuid" \
      || erro_fatal "Falha ao gravar o Klipper via CAN"
  fi
  sucesso "Primeiro flash completo: $nome rodando Klipper!"
}

_flash_adaptador() {
  # Adaptadores USB-CAN (U2C, UTOC) não rodam Katapult/Klipper:
  # recebem um binário direto via dfu-util, conforme o perfil.
  local perfil="$1" url cmd arquivo vids vp
  url=$(yq eval '.adaptador.firmware' "$perfil")
  cmd=$(yq eval '.adaptador.comando' "$perfil")
  vids=$(yq eval '.bootloader.vid_pid[]' "$perfil" 2>/dev/null | tr '\n' ' ')
  [ -n "$url" ] && [ "$url" != "null" ] || erro_fatal "Perfil de adaptador sem 'adaptador.firmware'"

  mkdir -p "$KLIPPERIZER_BASE/out"
  arquivo="$KLIPPERIZER_BASE/out/$(basename "$url")"
  aviso "Baixando firmware do adaptador..."
  wget -qO "$arquivo" "$url" || erro_fatal "Falha no download do firmware"

  aviso "Coloque o adaptador em modo DFU agora:"
  aviso "$(yq eval '.bootloader.instrucoes' "$perfil")"
  vp=$(esperar_dfu "$vids" 300) || erro_fatal "DFU não detectado ($vids)."
  sucesso "Dispositivo detectado: $vp — gravando..."

  cmd="${cmd//\{vidpid\}/$vp}"
  cmd="${cmd//\{arquivo\}/$arquivo}"
  bash -c "$cmd" || erro_fatal "Falha ao gravar o adaptador"
  sucesso "Adaptador gravado!"
}
