#!/usr/bin/env bash
# Generate vara.ini and varafm.ini for All In One Cable (USB audio) under a profile
# directory for tools like varanny to swap at runtime.
#
# Default profile dir: /opt/vara/profiles/all-in-one-cable
# Override: -o DIR or VARA_PROFILE_DIR (-o wins).
#
# Interactive: prompts for callsign and registration code.
# Non-interactive: stdin not a TTY and both VARA_CALLSIGN and VARA_REGISTRATION_CODE set.

set -euo pipefail

readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: create-vara-ini-all-in-one-cable.sh [-o DIR]

  -o DIR   Profile directory (default: /opt/vara/profiles/all-in-one-cable, or $VARA_PROFILE_DIR)

Writes vara.ini and varafm.ini with All-In-One-Cable sound device strings. Fills:
  Registration Code, Callsign Licence 0

Interactive: enter callsign and VARA license when prompted.
Non-interactive: set VARA_CALLSIGN and VARA_REGISTRATION_CODE (stdin must not be a TTY).

Files are chmod 600. Point varanny (or similar) at this directory to swap configs.
USAGE
}

validate_fields() {
  local callsign=$1 reg=$2
  [[ -n "$callsign" ]] || die "callsign is empty"
  [[ -n "$reg" ]] || die "registration code is empty"
  [[ "$callsign" != *$'\n'* && "$reg" != *$'\n'* ]] || die "values must not contain newlines"
  [[ "$callsign" != *=* ]] || die "callsign must not contain '='"
  [[ "$reg" != *=* ]] || die "registration code must not contain '='"
}

collect_inputs() {
  if [[ ! -t 0 ]] && [[ -n "${VARA_CALLSIGN:-}" ]] && [[ -n "${VARA_REGISTRATION_CODE:-}" ]]; then
    CALLSIGN=$VARA_CALLSIGN
    REGISTRATION_CODE=$VARA_REGISTRATION_CODE
    validate_fields "$CALLSIGN" "$REGISTRATION_CODE"
    return
  fi
  if [[ ! -t 0 ]]; then
    die "stdin is not a terminal; set VARA_CALLSIGN and VARA_REGISTRATION_CODE for non-interactive use"
  fi

  local line
  read -rp "Callsign: " line || die "read failed"
  CALLSIGN=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  read -rsp "VARA registration code (hidden): " REGISTRATION_CODE || die "read failed"
  echo
  validate_fields "$CALLSIGN" "$REGISTRATION_CODE"
}

resolve_profile_dir() {
  if [[ -n "${OPT_OUT_DIR:-}" ]]; then
    printf '%s' "$OPT_OUT_DIR"
  elif [[ -n "${VARA_PROFILE_DIR:-}" ]]; then
    printf '%s' "$VARA_PROFILE_DIR"
  else
    printf '%s' "${VARA_ROOT}/profiles/all-in-one-cable"
  fi
}

write_vara_ini() {
  local out=$1
  cat >"$out" <<INI
[Soundcard]
Input Device Name=In: All-In-One-Cable - USB Audi
Output Device Name=Out: All-In-One-Cable - USB Aud
ALC Drive Level=-5
Channel=0
[Setup]
Registration Code=${REGISTRATION_CODE}
Callsign Licence 0=${CALLSIGN}
WaterFall=0
TCP Command Port=8300
Retries=20
View=3
CW ID=0
RA-Board PTT=0
Compatibility=0
Updates=0
ATU=0
Encryption=0
Persistence=0.4
Enable KISS=0
KISS Port=8100
[Monitor]
Monitor Mode=0
INI
}

write_varafm_ini() {
  local out=$1
  cat >"$out" <<INI
[Soundcard]
Input Device Name=In: All-In-One-Cable - USB Audi
Output Device Name=Out: All-In-One-Cable - USB Aud
ALC Drive Level=-5
Channel=0
[Setup]
Registration Code=${REGISTRATION_CODE}
Callsign Licence 0=${CALLSIGN}
Updates=0
Enable KISS=0
KISS Port=8100
TCP Command Port=8300
TCP Scan Port=8427
Retries=10
FM Mode=1
View=3
Encryption=0
INI
}

main() {
  local a opt
  for a in "$@"; do
    if [[ "$a" == "--help" ]]; then
      usage
      exit 0
    fi
  done

  OPT_OUT_DIR=
  while getopts 'o:h' opt; do
    case $opt in
      o) OPT_OUT_DIR=$OPTARG ;;
      h) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  local PROFILE_DIR
  PROFILE_DIR=$(resolve_profile_dir)
  PROFILE_DIR=$(readlink -f "$PROFILE_DIR" 2>/dev/null || printf '%s' "$PROFILE_DIR")

  collect_inputs

  mkdir -p "$PROFILE_DIR"

  local f_vara f_fm
  f_vara="${PROFILE_DIR}/vara.ini"
  f_fm="${PROFILE_DIR}/varafm.ini"

  write_vara_ini "$f_vara"
  write_varafm_ini "$f_fm"
  chmod 600 "$f_vara" "$f_fm"

  echo
  echo "Wrote (mode 600):"
  echo "  $f_vara"
  echo "  $f_fm"
  echo "Configure varanny (or your swapper) to use profile directory: $PROFILE_DIR"
}

main "$@"
