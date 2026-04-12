#!/usr/bin/env bash
# Install VARA FM and VARA HF from previously downloaded/unzipped Winlink installers using Wine.
# Expects setup EXEs under VARA_INSTALLERS_DIR (default: /opt/vara/installers).
#
# Loads /opt/vara/config/wine.env if present (WINEPREFIX, WINEARCH, DISPLAY). If DISPLAY is
# still unset, uses VARA_WINE_DISPLAY, then DISPLAY, then :1 (Xvfb).
#
# Inno Setup unattended: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /CLOSEAPPLICATIONS
# /FORCECLOSEAPPLICATIONS /LOG=...  (see JRSoftware Inno Setup “Setup Command Line Parameters”).
# Custom [Code] MsgBox() dialogs cannot always be suppressed; then VARA_WINE_INSTALL_TIMEOUT_SEC
# kills the run so the next installer still runs (default 180s; 0 = no limit).
#
# After install, runs create-vara-launchers.sh to add /opt/vara/libexec/vara-fm and vara-hf (override
# bin dir with VARA_LAUNCHER_BIN).

set -euo pipefail

readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"
readonly DEFAULT_INSTALLERS_DIR="${VARA_INSTALLERS_DIR:-$VARA_ROOT/installers}"
readonly DEFAULT_WINE_ENV="${VARA_ROOT}/config/wine.env"
readonly DEFAULT_LOG_DIR="${VARA_INSTALL_LOG_DIR:-$VARA_ROOT/logs}"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: install-vara.sh [options]

  -d DIR   Installer directory (default: /opt/vara/installers or $VARA_INSTALLERS_DIR)
  -h       Help

Requires: wine, extracted VARA FM/HF *.exe from Winlink zips. Run download-vara-installers.sh first.

Creates /opt/vara/libexec/vara-fm and vara-hf unless VARA_SKIP_LAUNCHERS=1.

Env:
  VARA_WINE_INSTALL_TIMEOUT_SEC   Max seconds per installer (default 180); 0 disables timeout.
                                  On timeout, logs a warning and continues with the next EXE.
  VARA_SKIP_LAUNCHERS             If set, do not run create-vara-launchers.sh at the end.
  VARA_LAUNCHER_BIN               Directory for vara-fm / vara-hf (default /opt/vara/libexec).
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

load_wine_env() {
  if [[ -f "$DEFAULT_WINE_ENV" ]]; then
    echo "Sourcing $DEFAULT_WINE_ENV"
    set -a
    # shellcheck disable=SC1090
    source "$DEFAULT_WINE_ENV"
    set +a
  fi
}

ensure_display() {
  if [[ -z "${DISPLAY:-}" ]]; then
    if [[ -n "${VARA_WINE_DISPLAY:-}" ]]; then
      DISPLAY=$VARA_WINE_DISPLAY
    else
      DISPLAY=:1
    fi
    export DISPLAY
  fi
  echo "Using DISPLAY=$DISPLAY"
}

warn_if_no_x_socket() {
  local d=$DISPLAY
  [[ "$d" == :* ]] || return 0
  local n=${d#:}
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  local sock=/tmp/.X11-unix/X$n
  if [[ ! -S "$sock" ]]; then
    echo "warning: $sock missing — Xvfb (or another X server) may not be running for $DISPLAY" >&2
  fi
}

# Latest match by sorting paths (version-like names sort last with sort -V).
find_latest_exe() {
  local dir=$1
  local glob_pat=$2
  local found
  found=$(find "$dir" -type f -iname "$glob_pat" 2>/dev/null | LC_ALL=C sort -V | tail -n1)
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

run_inno_silent() {
  local exe=$1
  local log_dir=$2
  local safe base logfile
  local timeout_sec rc

  [[ -f "$exe" ]] || die "not a file: $exe"
  require_cmd wine

  mkdir -p "$log_dir"
  base=$(basename "$exe" .exe)
  safe=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')
  logfile="${log_dir}/${safe}.log"

  timeout_sec=${VARA_WINE_INSTALL_TIMEOUT_SEC:-180}

  echo "Running: wine \"$exe\" … /LOG=$logfile"
  if [[ "$timeout_sec" =~ ^[0-9]+$ ]] && [[ "$timeout_sec" -gt 0 ]]; then
    require_cmd timeout
    echo "  (hard stop after ${timeout_sec}s; VARA_WINE_INSTALL_TIMEOUT_SEC=0 to disable)"
  fi

  set +e
  if [[ "$timeout_sec" =~ ^[0-9]+$ ]] && [[ "$timeout_sec" -gt 0 ]]; then
    # -k: SIGKILL after 30s if the process ignores SIGTERM (stuck dialog under Wine).
    timeout -k 30 "$timeout_sec" wine "$exe" \
      /VERYSILENT \
      /SUPPRESSMSGBOXES \
      /NORESTART \
      /SP- \
      /CLOSEAPPLICATIONS \
      /FORCECLOSEAPPLICATIONS \
      "/LOG=$logfile"
    rc=$?
  else
    wine "$exe" \
      /VERYSILENT \
      /SUPPRESSMSGBOXES \
      /NORESTART \
      /SP- \
      /CLOSEAPPLICATIONS \
      /FORCECLOSEAPPLICATIONS \
      "/LOG=$logfile"
    rc=$?
  fi
  set -e

  if [[ "$rc" -eq 124 ]]; then
    echo "warning: installer hit ${timeout_sec}s timeout (likely a dialog); continuing. See: $logfile" >&2
    return 0
  fi
  if [[ "$rc" -ne 0 ]]; then
    die "wine installer exited with status $rc (log: $logfile)"
  fi
}

main() {
  local installers_dir=$DEFAULT_INSTALLERS_DIR
  local opt

  while getopts 'd:h' opt; do
    case $opt in
      d) installers_dir=$OPTARG ;;
      h) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  [[ $EUID -eq 0 ]] && die "run as a normal user (not root); wine should use your prefix"

  require_cmd find
  load_wine_env
  ensure_display
  warn_if_no_x_socket

  [[ -d "$installers_dir" ]] || die "installer directory not found: $installers_dir"

  [[ -n "${WINEPREFIX:-}" ]] && echo "WINEPREFIX=$WINEPREFIX"
  [[ -n "${WINEARCH:-}" ]] && echo "WINEARCH=$WINEARCH"

  local fm_exe hf_exe
  fm_exe=$(find_latest_exe "$installers_dir" '*vara*fm*.exe') ||
    die "no VARA FM setup *.exe under $installers_dir (download and unzip Winlink installer first)"
  # VARA HF setup.exe is named 'vara setup', there is no HF in the name
  hf_exe=$(find_latest_exe "$installers_dir" '*vara setup*.exe') ||
    die "no VARA HF setup *.exe under $installers_dir (download and unzip Winlink installer first)"

  echo "VARA FM: $fm_exe"
  run_inno_silent "$fm_exe" "$DEFAULT_LOG_DIR"

  echo "VARA HF: $hf_exe"
  run_inno_silent "$hf_exe" "$DEFAULT_LOG_DIR"

  local _here
  _here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -z "${VARA_SKIP_LAUNCHERS:-}" && -f "${_here}/create-vara-launchers.sh" ]]; then
    echo
    # VARA_LAUNCHER_BIN is read by create-vara-launchers.sh via the environment.
    bash "${_here}/create-vara-launchers.sh"
  fi

  echo
  echo "Done. Inno logs: $DEFAULT_LOG_DIR"
}

main "$@"
