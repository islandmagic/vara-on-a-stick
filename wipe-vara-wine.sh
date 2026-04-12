#!/usr/bin/env bash
# Remove the VARA Wine prefix and /opt/vara runtime data so you can rerun setup-wine-for-vara.sh
# and the download/install/profile steps from scratch.
#
# Default mode deletes (overridable with env — see below):
#   - WINEPREFIX (default: /opt/vara/wineprefixes/vara)
#   - /opt/vara/installers, logs, profiles, libexec/*, and /opt/vara/config/wine.env
#
# Default mode does NOT remove /opt/vara/bin/varanny, /opt/vara/config/varanny.json,
# /opt/vara/scripts, or varanny.service.
#
# With --all: removes the entire VARA_ROOT tree (including bin, config, scripts, wineprefixes),
# stops/disables/removes varanny.service, and uses sudo when not root. Run:
#   ./wipe-vara-wine.sh --all
# or (same):
#   sudo ./wipe-vara-wine.sh --all
#
# Optional: strip the setup-wine-for-vara ~/.bashrc hook (--strip-bashrc). With --all as root,
# VARA_USER (default ham) selects whose ~/.bashrc is edited when combined with --strip-bashrc.

set -euo pipefail

readonly MARK_BEGIN='# >>> vara-wine-debian'
readonly MARK_END='# <<< vara-wine-debian'
readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"
readonly SYSTEMD_VARANNY_UNIT="${SYSTEMD_VARANNY_UNIT:-/etc/systemd/system/varanny.service}"
readonly DEFAULT_VARA_USER="${DEFAULT_VARA_USER:-ham}"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: wipe-vara-wine.sh [options]

  -y, --yes          Do not prompt for confirmation
  --all              Remove all of VARA_ROOT (incl. bin, scripts, wineprefixes) and varanny.service;
                     uses sudo when needed (or run as root). Implies removing Wine prefix in default layout.
  --strip-bashrc     Remove the VARA wine.env block from ~/.bashrc (see setup-wine-for-vara.sh).
                     With --all as root, uses VARA_USER's home (default ham).
  -h, --help         This help

Environment (optional overrides — use only if you customized paths):
  VARA_WIPE_PREFIX       Wine prefix directory (default: /opt/vara/wineprefixes/vara)
  VARA_ROOT              VARA install root (default: /opt/vara)
  VARA_WIPE_OPT_SUBDIRS  If set to 0, skip removing installers/logs/profiles/libexec (default: wipe them;
                         ignored with --all)
  VARA_USER              Wine/varanny user for stop-wine and --strip-bashrc when running as root (default ham)

Default mode: run as the same user that runs Wine (e.g. ham), not root.
With --all: run as that user (sudo will prompt) or as root for a full appliance reset.
USAGE
}

resolve_wipe_user() {
  if [[ $EUID -eq 0 ]]; then
    WIPE_USER="${VARA_USER:-$DEFAULT_VARA_USER}"
  elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    WIPE_USER=$SUDO_USER
  else
    WIPE_USER=$(id -un)
  fi
}

require_sudo_if_needed() {
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo is required for --all (or run as root)"
  sudo -n true 2>/dev/null || {
    echo "Full wipe needs sudo to remove root-owned paths under $VARA_ROOT and $SYSTEMD_VARANNY_UNIT."
    sudo true
  }
}

sudo_rm_rf() {
  local path=$1
  [[ $EUID -eq 0 ]] && rm -rf "$path" && return 0
  sudo rm -rf "$path"
}

# Refuse obviously dangerous VARA_ROOT values for --all.
ensure_vara_root_safe_for_full_wipe() {
  local canon parent
  canon=$(readlink -f "$VARA_ROOT" 2>/dev/null) || die "cannot resolve VARA_ROOT"
  [[ -n "$canon" && "$canon" != / ]] || die "refusing VARA_ROOT=$canon"
  parent=$(dirname "$canon")
  [[ "$parent" != / ]] || die "refusing VARA_ROOT=$canon (must not be a top-level directory under /)"
  case $canon in
    /bin | /boot | /dev | /etc | /lib | /lib64 | /opt | /proc | /run | /sbin | /sys | /usr | /var)
      die "refusing VARA_ROOT=$canon"
      ;;
  esac
  local home_canon
  home_canon=$(readlink -f "$HOME" 2>/dev/null || printf '%s' "$HOME")
  [[ "$canon" != "$home_canon" && "$canon" != "$home_canon"/* ]] ||
    die "refusing VARA_ROOT under HOME: $canon"
}

stop_wine_for_prefix() {
  local pfx=$1
  [[ -d "$pfx" ]] || return 0
  command -v wineserver >/dev/null 2>&1 || return 0
  echo "Stopping Wine (WINEPREFIX=$pfx)..."
  if [[ $EUID -eq 0 && "$(id -un)" != "$WIPE_USER" ]]; then
    sudo -u "$WIPE_USER" env WINEPREFIX="$pfx" WINEDEBUG=-all wineserver -k 2>/dev/null || true
    sleep 1
    sudo -u "$WIPE_USER" env WINEPREFIX="$pfx" WINEDEBUG=-all wineserver -k9 2>/dev/null || true
  else
    env WINEPREFIX="$pfx" WINEDEBUG=-all wineserver -k 2>/dev/null || true
    sleep 1
    env WINEPREFIX="$pfx" WINEDEBUG=-all wineserver -k9 2>/dev/null || true
  fi
}

load_wineprefix_from_env_files() {
  local f
  for f in "${VARA_ROOT}/config/wine.env" "${HOME}/.config/vara/wine.env"; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    set -a
    source "$f"
    set +a
    return 0
  done
}

# Allow wiping a prefix under $HOME (legacy) or under /opt/vara.
ensure_wipe_prefix_safe() {
  local path=$1 label=$2
  local canon home_canon root_canon
  canon=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
  home_canon=$(readlink -f "$HOME" 2>/dev/null || printf '%s' "$HOME")
  root_canon=$(readlink -f "$VARA_ROOT" 2>/dev/null || printf '%s' "$VARA_ROOT")
  [[ "$canon" == "$home_canon" || "$canon" == "$home_canon"/* || "$canon" == "$root_canon"/* ]] ||
    die "refusing $label: path must be under HOME or $VARA_ROOT: $canon"
}

ensure_under_opt_vara() {
  local path=$1 label=$2
  local canon root_canon
  canon=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
  root_canon=$(readlink -f "$VARA_ROOT" 2>/dev/null || printf '%s' "$VARA_ROOT")
  [[ "$canon" == "$root_canon"/* || "$canon" == "$root_canon" ]] ||
    die "refusing $label: path must be under $root_canon: $canon"
}

strip_bashrc_hook() {
  local rc=$1
  local bak newf
  [[ -f "$rc" ]] || {
    echo "No $rc; skipping --strip-bashrc."
    return 0
  }
  grep -qF "$MARK_BEGIN" "$rc" 2>/dev/null || {
    echo "$rc has no VARA hook ($MARK_BEGIN); nothing to strip."
    return 0
  }
  bak="${rc}.bak.vara-wipe.$(date +%Y%m%d%H%M%S)"
  cp -a "$rc" "$bak"
  newf=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    BEGIN { del=0 }
    index($0, b) > 0 { del=1 }
    del && index($0, e) > 0 { del=0; next }
    del { next }
    { print }
  ' "$rc" >"$newf"
  if [[ $EUID -eq 0 ]]; then
    chown "${WIPE_USER}:${WIPE_USER}" "$newf"
    chmod 644 "$newf"
  fi
  mv "$newf" "$rc"
  echo "Removed VARA hook from $rc (backup: $bak)"
}

resolve_bashrc_for_strip() {
  if [[ $EUID -eq 0 ]]; then
    local home_dir
    home_dir=$(getent passwd "$WIPE_USER" | cut -d: -f6)
    [[ -n "$home_dir" ]] || die "no passwd entry for VARA_USER/WIPE_USER=$WIPE_USER"
    printf '%s' "${home_dir}/.bashrc"
  else
    printf '%s' "${HOME}/.bashrc"
  fi
}

wipe_varanny_systemd() {
  [[ -f "$SYSTEMD_VARANNY_UNIT" ]] || {
    echo "Skip (missing): $SYSTEMD_VARANNY_UNIT"
    return 0
  }
  echo "Stopping and disabling varanny.service..."
  if [[ $EUID -eq 0 ]]; then
    systemctl stop varanny.service 2>/dev/null || true
    systemctl disable varanny.service 2>/dev/null || true
    rm -f "$SYSTEMD_VARANNY_UNIT"
    systemctl daemon-reload
  else
    sudo systemctl stop varanny.service 2>/dev/null || true
    sudo systemctl disable varanny.service 2>/dev/null || true
    sudo rm -f "$SYSTEMD_VARANNY_UNIT"
    sudo systemctl daemon-reload
  fi
  echo "Removed $SYSTEMD_VARANNY_UNIT"
}

wipe_user_config_vara() {
  local cfg
  if [[ $EUID -eq 0 ]]; then
    local home_dir
    home_dir=$(getent passwd "$WIPE_USER" | cut -d: -f6)
    [[ -n "$home_dir" ]] || return 0
    cfg="${home_dir}/.config/vara"
  else
    cfg="${HOME}/.config/vara"
  fi
  if [[ -e "$cfg" ]]; then
    echo "Removing $cfg"
    if [[ $EUID -eq 0 && "$(id -un)" != "$WIPE_USER" ]]; then
      sudo -u "$WIPE_USER" rm -rf "$cfg" 2>/dev/null || sudo rm -rf "$cfg"
    else
      rm -rf "$cfg"
    fi
  else
    echo "Skip (missing): $cfg"
  fi
}

wipe_opt_vara_user_data() {
  local d
  for d in "${VARA_ROOT}/installers" "${VARA_ROOT}/logs" "${VARA_ROOT}/profiles"; do
    ensure_under_opt_vara "$d" "VARA data dir"
    if [[ -e "$d" ]]; then
      echo "Removing $d"
      rm -rf "$d"
    else
      echo "Skip (missing): $d"
    fi
  done

  if [[ -d "${VARA_ROOT}/libexec" ]]; then
    ensure_under_opt_vara "${VARA_ROOT}/libexec" "libexec"
    echo "Clearing ${VARA_ROOT}/libexec/*"
    find "${VARA_ROOT}/libexec" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi

  local wine_env="${VARA_ROOT}/config/wine.env"
  if [[ -f "$wine_env" ]]; then
    ensure_under_opt_vara "$wine_env" "wine.env"
    echo "Removing $wine_env"
    rm -f "$wine_env"
  else
    echo "Skip (missing): $wine_env"
  fi
}

prefix_is_under_vara_root() {
  local pfx=$1
  local pfx_c root_c
  pfx_c=$(readlink -f "$pfx" 2>/dev/null || printf '%s' "$pfx")
  root_c=$(readlink -f "$VARA_ROOT" 2>/dev/null || printf '%s' "$VARA_ROOT")
  [[ "$pfx_c" == "$root_c" || "$pfx_c" == "$root_c"/* ]]
}

main() {
  local yes=0 strip_rc=0 all=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y | --yes) yes=1 ;;
      --all) all=1 ;;
      --strip-bashrc) strip_rc=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown option: $1 (use -h)" ;;
    esac
    shift
  done

  [[ $EUID -eq 0 && "$all" -eq 0 ]] && die "run as your normal user (e.g. ham), not root (use --all for full wipe as root)"

  resolve_wipe_user

  local prefix
  prefix="${VARA_WIPE_PREFIX:-${VARA_ROOT}/wineprefixes/vara}"

  load_wineprefix_from_env_files
  [[ -n "${WINEPREFIX:-}" ]] && prefix="$WINEPREFIX"

  ensure_wipe_prefix_safe "$prefix" "VARA_WIPE_PREFIX/WINEPREFIX"

  if [[ "$all" -eq 1 ]]; then
    require_sudo_if_needed
    ensure_vara_root_safe_for_full_wipe
  fi

  echo "This will permanently delete:"
  echo "  Wine prefix: $prefix"
  if [[ "$all" -eq 1 ]]; then
    echo "  Entire tree: $VARA_ROOT"
    echo "  Systemd unit: $SYSTEMD_VARANNY_UNIT (if present)"
    echo "  ${WIPE_USER} ~/.config/vara (if present)"
  elif [[ "${VARA_WIPE_OPT_SUBDIRS:-1}" != "0" ]]; then
    echo "  ${VARA_ROOT}/installers, logs, profiles"
    echo "  ${VARA_ROOT}/libexec/*"
    echo "  ${VARA_ROOT}/config/wine.env"
  fi
  [[ "$strip_rc" -eq 1 ]] && echo "  VARA block in target ~/.bashrc (between $MARK_BEGIN and $MARK_END)"
  echo
  if [[ "$all" -eq 0 ]]; then
    echo "Not removed: ${VARA_ROOT}/bin/varanny, ${VARA_ROOT}/config/varanny.json, ${VARA_ROOT}/scripts"
    echo
  fi
  if [[ "$yes" -eq 0 ]]; then
    read -r -p "Type YES to continue: " reply || die "read failed"
    [[ "$reply" == "YES" ]] || die "aborted"
  fi

  stop_wine_for_prefix "$prefix"

  if [[ "$all" -eq 1 ]]; then
    wipe_varanny_systemd
    if ! prefix_is_under_vara_root "$prefix"; then
      if [[ -e "$prefix" ]]; then
        echo "Removing prefix outside $VARA_ROOT: $prefix"
        sudo_rm_rf "$prefix"
      fi
    fi
    if [[ -e "$VARA_ROOT" ]]; then
      echo "Removing $VARA_ROOT"
      sudo_rm_rf "$VARA_ROOT"
    else
      echo "Skip (missing): $VARA_ROOT"
    fi
    wipe_user_config_vara
  else
    if [[ -e "$prefix" ]]; then
      echo "Removing $prefix"
      rm -rf "$prefix"
    else
      echo "Skip (missing): $prefix"
    fi

    if [[ "${VARA_WIPE_OPT_SUBDIRS:-1}" != "0" ]]; then
      wipe_opt_vara_user_data
    fi
  fi

  [[ "$strip_rc" -eq 1 ]] && strip_bashrc_hook "$(resolve_bashrc_for_strip)"

  echo
  if [[ "$all" -eq 1 ]]; then
    echo "Done (full wipe). Re-run setup-headless-prereqs.sh (for /opt/vara layout), setup-wine-for-vara.sh, and install-varanny.sh as needed."
  else
    echo "Done. Next: ./setup-wine-for-vara.sh then download/install VARA and profiles as needed."
  fi
}

main "$@"
