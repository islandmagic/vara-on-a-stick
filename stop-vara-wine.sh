#!/usr/bin/env bash
# Stop Wine processes for the VARA prefix after a cancelled or hung installer.
# Those OLE errors (CoReleaseMarshalData, CoGetContextToken) are usually harmless COM
# cleanup spam from threads that lost their parent when the session was interrupted.
#
# Usage: ./stop-vara-wine.sh [--force]
#   --force  Also SIGKILL stray wine* processes for your user (use if -k is not enough).

set -euo pipefail

readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"

die() {
  echo "error: $*" >&2
  exit 1
}

load_wine_env() {
  local envf="${VARA_WINE_ENV:-/opt/vara/config/wine.env}"
  if [[ ! -f "$envf" && -f "${HOME}/.config/vara/wine.env" ]]; then
    envf="${HOME}/.config/vara/wine.env"
  fi
  if [[ -f "$envf" ]]; then
    echo "Sourcing $envf"
    set -a
    # shellcheck disable=SC1090
    source "$envf"
    set +a
  fi
  : "${WINEPREFIX:=${VARA_ROOT}/wineprefixes/vara}"
  export WINEPREFIX
  echo "WINEPREFIX=$WINEPREFIX"
}

graceful_stop() {
  command -v wineserver >/dev/null 2>&1 || {
    echo "wineserver not on PATH; try: pkill -u \"\$(id -un)\" -x wineserver"
    return 1
  }
  echo "Asking wineserver to shut down (SIGTERM)..."
  wineserver -k 2>/dev/null || true
  sleep 2
  echo "Force wineserver shutdown (SIGKILL) if still up..."
  wineserver -k9 2>/dev/null || true
}

force_user_wine_pkill() {
  echo "Sending SIGTERM to remaining wine processes for user $(id -un)..."
  pkill -u "$(id -u)" -TERM -f 'wineserver' 2>/dev/null || true
  pkill -u "$(id -u)" -TERM -f 'wine.*preloader' 2>/dev/null || true
  pkill -u "$(id -u)" -TERM -f 'wine64-preloader' 2>/dev/null || true
  pkill -u "$(id -u)" -TERM -f 'wineboot' 2>/dev/null || true
  sleep 2
  echo "SIGKILL stragglers..."
  pkill -u "$(id -u)" -KILL -f 'wineserver' 2>/dev/null || true
  pkill -u "$(id -u)" -KILL -f 'wine.*preloader' 2>/dev/null || true
  pkill -u "$(id -u)" -KILL -f 'wine64-preloader' 2>/dev/null || true
}

usage() {
  cat <<'USAGE'
Stop Wine processes for the VARA prefix after a cancelled or hung installer.

Usage: stop-vara-wine.sh [--force]

  --force   Also SIGKILL stray wine processes for your user (if wineserver -k is not enough)

Run as the same user that runs Wine (not root).
USAGE
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
    usage
    exit 0
  }

  [[ $EUID -eq 0 ]] && die "run as your normal user (same as wine), not root"

  load_wine_env
  graceful_stop || true

  if [[ "${1:-}" == "--force" ]]; then
    force_user_wine_pkill
  fi

  echo
  if pgrep -u "$(id -u)" -af '(wineserver|wine.*preloader|wine64-preloader)' >/dev/null 2>&1; then
    echo "Some wine processes may still be running:"
    pgrep -u "$(id -u)" -af '(wineserver|wine.*preloader|wine64-preloader)' || true
    echo "Re-run with --force or: pkill -u \"\$(id -un)\" -f wine"
  else
    echo "No matching wine processes found."
  fi
  echo
  echo "To quiet Wine log noise on future runs: export WINEDEBUG=-all"
}

main "$@"
