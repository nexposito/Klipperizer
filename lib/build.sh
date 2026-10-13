# ============================================================
#  Klipperizer — Módulo de compilação
#  O .config é gerado das listas CONFIG_* do perfil YAML e o
#  'make olddefconfig' completa o resto com padrões. A verificação
#  de símbolos abaixo impede compilar config errada em silêncio:
#  se um símbolo do perfil não existir no Kconfig, o build falha
#  com mensagem clara em vez de seguir com valores padrão.
# ============================================================

gerar_config() {
  # $1 perfil | $2 seção (katapult|klipper) | $3 modo (can|usb) | $4 saída
  local perfil="$1" secao="$2" modo="$3" saida="$4"
  {
    echo "# Gerado pelo Klipperizer — não edite manualmente"
    yq eval ".${secao}.comum[]" "$perfil" 2>/dev/null || true
    yq eval ".${secao}.${modo}[]" "$perfil" 2>/dev/null || true
  } | sed '/^null$/d; /^[[:space:]]*$/d' > "$saida"
}

verificar_simbolos() {
  # $1 .config | $2 perfil | $3 seção | $4 modo
  local cfg="$1" perfil="$2" secao="$3" modo="$4" s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    [ "$s" = "null" ] && continue
    if ! grep -q "^${s%%=*}=" "$cfg"; then
      erro_fatal "Símbolo '${s%%=*}' do perfil não existe no Kconfig de $secao. Valide o YAML em: $perfil"
    fi
  done < <({ yq eval ".${secao}.comum[]" "$perfil" 2>/dev/null; yq eval ".${secao}.${modo}[]" "$perfil" 2>/dev/null; } | sed '/^null$/d; /^[[:space:]]*$/d')
}

compilar() {
  local perfil="$1" modo="$2" kdir="$3" katdir="$4"
  local jobs
  jobs=$(nproc)

  aviso "Compilando Katapult (interface: $modo)..."
  gerar_config "$perfil" katapult "$modo" "$katdir/.config"
  make -C "$katdir" olddefconfig >/dev/null
  verificar_simbolos "$katdir/.config" "$perfil" katapult "$modo"
  make -C "$katdir" -j"$jobs" >/dev/null

  aviso "Compilando Klipper (interface: $modo)..."
  gerar_config "$perfil" klipper "$modo" "$kdir/.config"
  make -C "$kdir" olddefconfig >/dev/null
  verificar_simbolos "$kdir/.config" "$perfil" klipper "$modo"
  make -C "$kdir" -j"$jobs" >/dev/null

  sucesso "Build concluído: $kdir/out/klipper.bin"
}
