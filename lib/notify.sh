# ============================================================
#  Klipperizer — Notifications (terminal + desktop notification)
# ============================================================

warn() {
  echo -e "\033[1;33m[WARNING]\033[0m $*"
  echo -e "\a"
  command -v notify-send >/dev/null 2>&1 && notify-send "Klipperizer" "$*" || true
}

success() {
  echo -e "\033[1;32m[OK]\033[0m $*"
  command -v notify-send >/dev/null 2>&1 && notify-send "Klipperizer" "$*" || true
}

fatal() {
  echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
  command -v notify-send >/dev/null 2>&1 && notify-send -u critical "Klipperizer" "$*" || true
  exit 1
}
