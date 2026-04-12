#!/usr/bin/env bash
# Create /opt/vara/libexec/vara-fm and vara-hf: source /opt/vara/config/wine.env (WINEPREFIX,
# WINEARCH, DISPLAY, …) then exec wine on the installed VARA EXE. Re-run after installing VARA.
#
# Usage: ./create-vara-launchers.sh [-b DIR]   (default DIR: /opt/vara/libexec)

set -euo pipefail

readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"
readonly DEFAULT_BIN="${VARA_LAUNCHER_BIN:-$VARA_ROOT/libexec}"

usage() {
  cat <<'USAGE'
Usage: create-vara-launchers.sh [-b DIR]

  -b DIR   Install directory for launchers (default: /opt/vara/libexec or $VARA_LAUNCHER_BIN)

Writes vara-fm and vara-hf. Add to PATH: export PATH="/opt/vara/libexec:$PATH"
Override installed EXE paths: VARA_FM_EXE / VARA_HF_EXE in the environment when running them.
USAGE
}

main() {
  local bindir=$DEFAULT_BIN opt

  while getopts 'b:h' opt; do
    case $opt in
      b) bindir=$OPTARG ;;
      h) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  mkdir -p "$bindir"

  cat >"$bindir/vara-fm" <<'FM'
#!/usr/bin/env bash
set -euo pipefail
: "${HOME?}"
ENV_FILE="${VARA_WINE_ENV:-/opt/vara/config/wine.env}"
[[ -f "$ENV_FILE" ]] || {
  echo "error: missing $ENV_FILE (e.g. run setup-wine-for-vara.sh)" >&2
  exit 1
}
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

WINE="${WINE:-wine}"

resolve_fm_exe() {
  if [[ -n "${VARA_FM_EXE:-}" && -f "$VARA_FM_EXE" ]]; then
    printf '%s\n' "$VARA_FM_EXE"
    return 0
  fi
  local p f
  for p in \
    "${WINEPREFIX}/drive_c/Program Files/VARA FM/VARAFM.exe" \
    "${WINEPREFIX}/drive_c/Program Files (x86)/VARA FM/VARAFM.exe"
  do
    [[ -f "$p" ]] && {
      printf '%s\n' "$p"
      return 0
    }
  done
  f=$(find "${WINEPREFIX}/drive_c" -type f -iname 'VARAFM.exe' 2>/dev/null | head -n1 || true)
  [[ -n "${f:-}" && -f "$f" ]] && {
    printf '%s\n' "$f"
    return 0
  }
  return 1
}

exe=$(resolve_fm_exe) || {
  echo "error: VARA FM.exe not found under ${WINEPREFIX}/drive_c; set VARA_FM_EXE" >&2
  exit 1
}

exec "$WINE" "$exe" "$@"
FM
  chmod +x "$bindir/vara-fm"

  cat >"$bindir/vara-hf" <<'HF'
#!/usr/bin/env bash
set -euo pipefail
: "${HOME?}"
ENV_FILE="${VARA_WINE_ENV:-/opt/vara/config/wine.env}"
[[ -f "$ENV_FILE" ]] || {
  echo "error: missing $ENV_FILE (e.g. run setup-wine-for-vara.sh)" >&2
  exit 1
}
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

WINE="${WINE:-wine}"

resolve_hf_exe() {
  if [[ -n "${VARA_HF_EXE:-}" && -f "$VARA_HF_EXE" ]]; then
    printf '%s\n' "$VARA_HF_EXE"
    return 0
  fi
  local p f
  for p in \
    "${WINEPREFIX}/drive_c/Program Files/VARA/VARA.exe" \
    "${WINEPREFIX}/drive_c/Program Files (x86)/VARA/VARA.exe"
  do
    [[ -f "$p" ]] && {
      printf '%s\n' "$p"
      return 0
    }
  done
  f=$(find "${WINEPREFIX}/drive_c" -type f -iname 'VARA.exe' 2>/dev/null | head -n1 || true)
  [[ -n "${f:-}" && -f "$f" ]] && {
    printf '%s\n' "$f"
    return 0
  }
  return 1
}

exe=$(resolve_hf_exe) || {
  echo "error: VARA HF.exe not found under ${WINEPREFIX}/drive_c; set VARA_HF_EXE" >&2
  exit 1
}

exec "$WINE" "$exe" "$@"
HF
  chmod +x "$bindir/vara-hf"

  echo "Installed:"
  echo "  $bindir/vara-fm"
  echo "  $bindir/vara-hf"
  echo "Add to PATH, e.g. in ~/.profile:"
  echo "  export PATH=\"$bindir:\$PATH\""
}

main "$@"
