#!/usr/bin/env bash
# Clone/build islandmagic/varanny, install binary under /opt/vara, write varanny.json with
# modem entries only for sound-card profiles that have both varafm.ini and vara.ini, and install
# a systemd unit (default User=ham, DISPLAY=:1, after xvfb).
#
# Launches VARA via /opt/vara/libexec/vara-fm and vara-hf (create-vara-launchers.sh). Varanny splits
# "Args" on spaces and passes a single empty arg when Args is blank; tiny helpers
# varanny-exec-fm / varanny-exec-hf exec those wrappers with no extra argv.
#
# Prerequisites: Unix user ham must already exist (e.g. Xvfb service). Go, git, Wine for ham,
# /opt/vara/config/wine.env (WINEPREFIX), /opt/vara/libexec/vara-fm and vara-hf, and at least one complete
# profile under /opt/vara/profiles/… (both INIs). DefaultConfig in varanny.json points at VARA's
# INIs under the Wine prefix (discovered under drive_c if present, else default install paths);
# if those files are missing, they are created with touch.
#
# Run with sudo from a checkout that includes helper scripts (copied to /opt/vara/scripts).

set -euo pipefail

readonly VARANNY_REPO="${VARANNY_REPO:-https://github.com/islandmagic/varanny.git}"
readonly VARANNY_SRC="${VARANNY_SRC:-/opt/varanny}"
readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"
readonly VARA_USER="${VARA_USER:-ham}"
readonly SYSTEMD_UNIT="/etc/systemd/system/varanny.service"
readonly PROFILE_SUBDIR_DIGIRIG="profiles/digirig-lite"
readonly PROFILE_SUBDIR_AIO="profiles/all-in-one-cable"
readonly VARA_WINE_ENV_FILE="${VARA_ROOT}/config/wine.env"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: sudo ./install-varanny.sh [options]

  --no-start     Enable unit only; do not start (or restart) varanny
  --no-enable    Write unit but do not systemctl enable
  -h, --help     This help

Environment:
  VARA_USER       Unix account for the service (default: ham). Must already exist.
  VARANNY_SRC     Clone directory (default: /opt/varanny)
  VARA_ROOT       Install prefix for bin + config (default: /opt/vara)
  VARANNY_REPO    Git URL

Copies create-vara-ini-*.sh and create-vara-launchers.sh to /opt/vara/scripts/ when present.

varanny.json lists FM+HF modems per profile that has *both* profile INIs:
  /opt/vara/profiles/digirig-lite/varafm.ini and vara.ini
  /opt/vara/profiles/all-in-one-cable/varafm.ini and vara.ini
At least one complete profile is required. Needs: jq (apt install jq).

DefaultConfig paths: VARA FM/HF .ini under \$WINEPREFIX/drive_c (search first; if missing, use
  drive_c/VARA FM/VARAFM.ini and drive_c/VARA/VARA.ini). Missing files are created empty (touch).
USAGE
}

require_root() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo)"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_service_user() {
  id -u "$VARA_USER" >/dev/null 2>&1 ||
    die "user '$VARA_USER' does not exist — create it first (this script does not add users)"
}

ensure_deps() {
  have_cmd git || die "install git"
  have_cmd go || die "install golang-go (apt install golang-go)"
  have_cmd jq || die "install jq (apt install jq) — required to write varanny.json"
}

clone_or_update() {
  if [[ -d "$VARANNY_SRC/.git" ]]; then
    echo "Updating $VARANNY_SRC"
    git -C "$VARANNY_SRC" pull --ff-only
  else
    echo "Cloning $VARANNY_REPO -> $VARANNY_SRC"
    mkdir -p "$(dirname "$VARANNY_SRC")"
    git clone "$VARANNY_REPO" "$VARANNY_SRC"
  fi
}

build_varanny() {
  mkdir -p "${VARA_ROOT}/bin"
  echo "Building varanny (CGO_ENABLED=1)..."
  (cd "$VARANNY_SRC" && CGO_ENABLED=1 go build -o "${VARA_ROOT}/bin/varanny" .)
  chmod 755 "${VARA_ROOT}/bin/varanny"
}

write_varanny_json() {
  local json=$1
  local fm_cmd=$2 hf_cmd=$3 fm_ini=$4 hf_ini=$5
  local dig_fm=$6 dig_hf=$7 aio_fm=$8 aio_hf=$9
  local inc_dig=${10} inc_aio=${11}

  jq -n \
    --arg fm_cmd "$fm_cmd" \
    --arg hf_cmd "$hf_cmd" \
    --arg fm_ini "$fm_ini" \
    --arg hf_ini "$hf_ini" \
    --arg dig_fm "$dig_fm" \
    --arg dig_hf "$dig_hf" \
    --arg aio_fm "$aio_fm" \
    --arg aio_hf "$aio_hf" \
    --argjson inc_dig "$inc_dig" \
    --argjson inc_aio "$inc_aio" \
    '
{
  Port: 8273,
  Delay: 0,
  Modems: (
    (if $inc_dig == 1 then [
      {Name: "DigirigLiteFM", Type: "fm", Cmd: $fm_cmd, DefaultConfig: $fm_ini, Config: $dig_fm},
      {Name: "DigirigLiteHF", Type: "hf", Cmd: $hf_cmd, DefaultConfig: $hf_ini, Config: $dig_hf}
    ] else [] end)
    +
    (if $inc_aio == 1 then [
      {Name: "AllInOneCableFM", Type: "fm", Cmd: $fm_cmd, DefaultConfig: $fm_ini, Config: $aio_fm},
      {Name: "AllInOneCableHF", Type: "hf", Cmd: $hf_cmd, DefaultConfig: $hf_ini, Config: $aio_hf}
    ] else [] end)
  )
}
' >"$json"
  chmod 640 "$json"
  chown root:"$VARA_USER" "$json" 2>/dev/null || true
}

# Sets include_dig / include_aio (0|1); warns on partial profiles.
resolve_profile_inclusion() {
  local dig_fm=$1 dig_hf=$2 aio_fm=$3 aio_hf=$4

  include_dig=0
  include_aio=0

  if [[ -f "$dig_fm" && -f "$dig_hf" ]]; then
    include_dig=1
  elif [[ -f "$dig_fm" || -f "$dig_hf" ]]; then
    echo "warning: incomplete Digirig Lite profile; skipping (need both INIs). Run create-vara-ini-digirig-lite.sh as $VARA_USER" >&2
    [[ -f "$dig_fm" ]] || echo "warning:   missing: $dig_fm" >&2
    [[ -f "$dig_hf" ]] || echo "warning:   missing: $dig_hf" >&2
  fi

  if [[ -f "$aio_fm" && -f "$aio_hf" ]]; then
    include_aio=1
  elif [[ -f "$aio_fm" || -f "$aio_hf" ]]; then
    echo "warning: incomplete All-In-One Cable profile; skipping (need both INIs). Run create-vara-ini-all-in-one-cable.sh as $VARA_USER" >&2
    [[ -f "$aio_fm" ]] || echo "warning:   missing: $aio_fm" >&2
    [[ -f "$aio_hf" ]] || echo "warning:   missing: $aio_hf" >&2
  fi

  if [[ "$include_dig" -eq 0 && "$include_aio" -eq 0 ]]; then
    die "no complete profile INIs for $VARA_USER — need both varafm.ini and vara.ini under ${VARA_ROOT}/${PROFILE_SUBDIR_DIGIRIG} and/or ${VARA_ROOT}/${PROFILE_SUBDIR_AIO} (see create-vara-ini-digirig-lite.sh / create-vara-ini-all-in-one-cable.sh as $VARA_USER)"
  fi
}

install_systemd_unit() {
  local wine_env=$VARA_WINE_ENV_FILE

  tee "$SYSTEMD_UNIT" >/dev/null <<UNIT
[Unit]
Description=varanny VARA launcher (DNS-SD)
After=network-online.target xvfb.service
Wants=network-online.target

[Service]
Type=simple
User=${VARA_USER}
Group=${VARA_USER}
Environment=DISPLAY=:1
EnvironmentFile=-${wine_env}
WorkingDirectory=${VARA_ROOT}
ExecStart=${VARA_ROOT}/bin/varanny -config ${VARA_ROOT}/config/varanny.json
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
}

copy_helper_scripts() {
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  mkdir -p "${VARA_ROOT}/scripts"
  for f in create-vara-ini-digirig-lite.sh create-vara-ini-all-in-one-cable.sh create-vara-launchers.sh; do
    if [[ -f "${here}/${f}" ]]; then
      install -m 0755 "${here}/${f}" "${VARA_ROOT}/scripts/${f}"
      echo "Installed ${VARA_ROOT}/scripts/${f}"
    fi
  done
}

# Varanny uses strings.Split(Args, " "); empty Args still yields a bogus empty argv element.
# These helpers ignore argv and exec the real launchers (wine.env via vara-fm / vara-hf).
install_varanny_exec_helpers() {
  mkdir -p "${VARA_ROOT}/libexec"
  chown "${VARA_USER}:${VARA_USER}" "${VARA_ROOT}/libexec"
  sudo -u "$VARA_USER" tee "${VARA_ROOT}/libexec/varanny-exec-fm" >/dev/null <<'EOS'
#!/usr/bin/env bash
exec "$(dirname "$0")/vara-fm"
EOS
  sudo -u "$VARA_USER" tee "${VARA_ROOT}/libexec/varanny-exec-hf" >/dev/null <<'EOS'
#!/usr/bin/env bash
exec "$(dirname "$0")/vara-hf"
EOS
  sudo -u "$VARA_USER" chmod 0755 "${VARA_ROOT}/libexec/varanny-exec-fm" "${VARA_ROOT}/libexec/varanny-exec-hf"
}

find_live_ini() {
  local user=$1 bas=$2
  sudo -u "$user" env ENV_FILE="$VARA_WINE_ENV_FILE" INI_BASENAME="$bas" bash -c '
    set -a
    # shellcheck disable=SC1090
    [[ -f "$ENV_FILE" ]] && . "$ENV_FILE"
    set +a
    find "${WINEPREFIX}/drive_c" -type f -iname "$INI_BASENAME" 2>/dev/null | head -n1
  '
}

get_wineprefix_for_user() {
  local user=$1
  sudo -u "$user" env ENV_FILE="$VARA_WINE_ENV_FILE" bash -c '
    set -a
    # shellcheck disable=SC1090
    [[ -f "$ENV_FILE" ]] && . "$ENV_FILE"
    set +a
    printf "%s\n" "${WINEPREFIX:-}"
  '
}

# DefaultConfig: prefer an existing .ini anywhere under drive_c; else VARA's usual install paths.
resolve_default_config_ini() {
  local user=$1 mode=$2
  local pfx found def

  pfx=$(get_wineprefix_for_user "$user")
  [[ -n "$pfx" ]] ||
    die "WINEPREFIX not set for $user — run setup-wine-for-vara.sh (needs ${VARA_WINE_ENV_FILE})"

  if [[ "$mode" == fm ]]; then
    found=$(find_live_ini "$user" 'VARAFM.ini')
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
    def="${pfx}/drive_c/VARA FM/VARAFM.ini"
    printf '%s\n' "$def"
    return 0
  fi

  if [[ "$mode" == hf ]]; then
    found=$(find_live_ini "$user" 'VARA.ini')
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
    def="${pfx}/drive_c/VARA/VARA.ini"
    printf '%s\n' "$def"
    return 0
  fi

  die "resolve_default_config_ini: bad mode: $mode"
}

# varanny expects DefaultConfig paths to exist; mkdir parent dirs under the Wine drive as needed.
ensure_default_ini_file() {
  local user=$1 path=$2
  if sudo -u "$user" test -f "$path"; then
    return 0
  fi
  echo "note: creating empty DefaultConfig file: $path" >&2
  sudo -u "$user" mkdir -p "$(dirname "$path")"
  sudo -u "$user" touch "$path"
}

main() {
  local no_start=0 no_enable=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-start) no_start=1 ;;
      --no-enable) no_enable=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done

  require_root
  ensure_deps
  require_service_user

  if [[ ! -f "$VARA_WINE_ENV_FILE" ]]; then
    echo "warning: $VARA_WINE_ENV_FILE missing — run setup-wine-for-vara.sh as $VARA_USER first." >&2
  fi

  clone_or_update
  mkdir -p "${VARA_ROOT}/config" "${VARA_ROOT}/libexec"
  chown "${VARA_USER}:${VARA_USER}" "${VARA_ROOT}/libexec" 2>/dev/null || true
  build_varanny
  copy_helper_scripts

  if [[ -x "${VARA_ROOT}/scripts/create-vara-launchers.sh" ]]; then
    echo "Ensuring ${VARA_ROOT}/libexec/vara-fm and vara-hf exist..."
    sudo -u "$VARA_USER" env VARA_LAUNCHER_BIN="${VARA_ROOT}/libexec" "${VARA_ROOT}/scripts/create-vara-launchers.sh" || true
  fi

  [[ -x "${VARA_ROOT}/libexec/vara-fm" ]] || die "missing executable ${VARA_ROOT}/libexec/vara-fm — run create-vara-launchers.sh as $VARA_USER"
  [[ -x "${VARA_ROOT}/libexec/vara-hf" ]] || die "missing executable ${VARA_ROOT}/libexec/vara-hf — run create-vara-launchers.sh as $VARA_USER"

  install_varanny_exec_helpers

  echo "Resolving DefaultConfig VARA .ini paths for user $VARA_USER..."
  local fm_cmd hf_cmd fm_ini hf_ini
  local profile_dig_fm profile_dig_hf profile_aio_fm profile_aio_hf

  fm_cmd="${VARA_ROOT}/libexec/varanny-exec-fm"
  hf_cmd="${VARA_ROOT}/libexec/varanny-exec-hf"

  profile_dig_fm="${VARA_ROOT}/${PROFILE_SUBDIR_DIGIRIG}/varafm.ini"
  profile_dig_hf="${VARA_ROOT}/${PROFILE_SUBDIR_DIGIRIG}/vara.ini"
  profile_aio_fm="${VARA_ROOT}/${PROFILE_SUBDIR_AIO}/varafm.ini"
  profile_aio_hf="${VARA_ROOT}/${PROFILE_SUBDIR_AIO}/vara.ini"

  fm_ini=$(resolve_default_config_ini "$VARA_USER" fm)
  hf_ini=$(resolve_default_config_ini "$VARA_USER" hf)
  ensure_default_ini_file "$VARA_USER" "$fm_ini"
  ensure_default_ini_file "$VARA_USER" "$hf_ini"

  resolve_profile_inclusion "$profile_dig_fm" "$profile_dig_hf" "$profile_aio_fm" "$profile_aio_hf"

  write_varanny_json "${VARA_ROOT}/config/varanny.json" \
    "$fm_cmd" "$hf_cmd" "$fm_ini" "$hf_ini" \
    "$profile_dig_fm" "$profile_dig_hf" "$profile_aio_fm" "$profile_aio_hf" \
    "$include_dig" "$include_aio"

  echo "Wrote ${VARA_ROOT}/config/varanny.json (profiles included: DigirigLite=$include_dig AllInOneCable=$include_aio)."

  install_systemd_unit

  systemctl daemon-reload
  if [[ "$no_enable" -eq 0 ]]; then
    systemctl enable varanny.service
  fi
  if [[ "$no_start" -eq 0 ]]; then
    systemctl restart varanny.service || systemctl start varanny.service
    systemctl --no-pager --full status varanny.service || true
  fi

  echo
  echo "varanny binary: ${VARA_ROOT}/bin/varanny"
  echo "Config:         ${VARA_ROOT}/config/varanny.json"
  local modem_note="via ${VARA_ROOT}/libexec/varanny-exec-* → vara-fm / vara-hf"
  if [[ "$include_dig" -eq 1 && "$include_aio" -eq 1 ]]; then
    echo "Modems:         Digirig Lite + All-In-One Cable ($modem_note)"
  elif [[ "$include_dig" -eq 1 ]]; then
    echo "Modems:         Digirig Lite only ($modem_note)"
  else
    echo "Modems:         All-In-One Cable only ($modem_note)"
  fi
  echo "Service user:   $VARA_USER (same as Xvfb in typical setups)"
}

main "$@"
