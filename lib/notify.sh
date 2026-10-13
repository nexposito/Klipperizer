# ============================================================
#  Klipperizer — Avisos (terminal + notificação de desktop)
# ============================================================

aviso() {
  echo -e "\033[1;33m[AVISO]\033[0m $*"
  echo -e "\a"
  command -v notify-send >/dev/null 2>&1 && notify-send "Klipperizer" "$*" || true
}

sucesso() {
  echo -e "\033[1;32m[OK]\033[0m $*"
  command -v notify-send >/dev/null 2>&1 && notify-send "Klipperizer" "$*" || true
}

erro_fatal() {
  echo -e "\033[1;31m[ERRO]\033[0m $*" >&2
  command -v notify-send >/dev/null 2>&1 && notify-send -u critical "Klipperizer" "$*" || true
  exit 1
}
