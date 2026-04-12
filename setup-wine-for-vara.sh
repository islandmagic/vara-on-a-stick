#!/usr/bin/env bash
# Install Wine, winetricks, and a 32-bit Wine prefix suitable for VARA on Debian.
# Run as a normal user; the script invokes sudo for apt/dpkg/source changes.
#
# - Enables apt "contrib" (classic sources.list and/or deb822 debian.sources).
# - Adds i386 multiarch.
# - Installs: wine, winetricks, exe-thumbnailer, winbind (Samba ntlm_auth for Wine NTLM)
# - Defines WINEPREFIX under /opt/vara/wineprefixes/vara and WINEARCH=win32.
# - Runs winetricks --unattended winxp sound=alsa dotnet35sp1 vb6run (once per prefix;
#   remove .vara-winetricks-extras in the prefix to force a re-run).
#
# Headless: set DISPLAY for Wine (e.g. Xvfb on :1 via systemd). If DISPLAY is unset,
# defaults to :1. Override with VARA_WINE_DISPLAY or DISPLAY when invoking this script.
#
# Afterward: source /opt/vara/config/wine.env (or open a new shell) before wine.

set -euo pipefail

readonly VARA_ROOT="${VARA_ROOT:-/opt/vara}"
readonly VARA_WINE_ENV_FILE="${VARA_ROOT}/config/wine.env"

readonly MARK_BEGIN="# >>> vara-wine-debian"
readonly MARK_END="# <<< vara-wine-debian"
readonly WINETRICKS_STAMP=".vara-winetricks-extras"

die() {
  echo "error: $*" >&2
  exit 1
}

require_debian() {
  [[ -f /etc/debian_version ]] || die "this script targets Debian (no /etc/debian_version)"
}

have_sudo() {
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  sudo -n true 2>/dev/null || {
    echo "sudo access is needed for apt and repository changes."
    sudo true
  }
}

# True if any deb line already mentions contrib (rough check).
sources_list_has_contrib() {
  [[ -f /etc/apt/sources.list ]] || return 1
  grep -qE '^[[:space:]]*deb[[:space:]].*[[:space:]]contrib([[:space:]]|$)' /etc/apt/sources.list
}

# Add contrib after "main" on deb lines that lack contrib (GNU sed).
enable_contrib_sources_list() {
  local f=/etc/apt/sources.list
  [[ -f "$f" ]] || return 0
  sources_list_has_contrib && return 0
  grep -qE '^[[:space:]]*deb[[:space:]].*[[:space:]]main([[:space:]]|$)' "$f" || return 0
  echo "Adding 'contrib' to $f (backup: ${f}.bak.<timestamp> on first change)."
  sudo cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  sudo sed -i '/^[[:space:]]*deb\>/s/[[:space:]]main\>/& contrib/g' "$f"
}

# deb822 e.g. Components: main non-free-firmware -> main contrib ...
enable_contrib_debian_sources() {
  local f
  (
    shopt -s nullglob
    for f in /etc/apt/sources.list.d/debian.sources \
             /etc/apt/sources.list.d/debian.sources.d/*.sources; do
      [[ -f "$f" ]] || continue
      grep -q '^Components:' "$f" || continue
      grep -qE '^Components:.*\<contrib\>' "$f" && continue
      echo "Adding 'contrib' to Components in $f"
      sudo cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
      sudo sed -i '/^Components:/{
        /contrib/b
        s/[[:space:]]main\>/& contrib/g
      }' "$f"
    done
  )
}

add_i386() {
  if dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
    echo "i386 architecture already enabled."
  else
    echo "Enabling i386 multiarch."
    sudo dpkg --add-architecture i386
  fi
}

apt_install_wine_stack() {
  export DEBIAN_FRONTEND=noninteractive
  echo "Updating apt indexes..."
  sudo apt-get update -y
  echo "Installing wine, winetricks, exe-thumbnailer, winbind (ntlm_auth)..."
  sudo apt-get install -y wine winetricks exe-thumbnailer winbind
}

# User running the script (not root) for prefix and config files.
resolve_target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    TARGET_USER=$SUDO_USER
  else
    TARGET_USER=${USER:-$(id -un)}
  fi
  TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "could not resolve home for user $TARGET_USER"
}

# Wine/winetricks need an X server even when unattended. Default :1 matches common Xvfb units.
resolve_wine_display() {
  if [[ -n "${VARA_WINE_DISPLAY:-}" ]]; then
    WINE_DISPLAY=$VARA_WINE_DISPLAY
  elif [[ -n "${DISPLAY:-}" ]]; then
    WINE_DISPLAY=$DISPLAY
  else
    WINE_DISPLAY=:1
  fi
  echo "Using DISPLAY=$WINE_DISPLAY for wine/winetricks (set DISPLAY or VARA_WINE_DISPLAY to override)."
}

warn_if_no_x_socket() {
  local d=$1
  [[ "$d" == :* ]] || return 0
  local n=${d#:}
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  local sock=/tmp/.X11-unix/X$n
  if [[ ! -S "$sock" ]]; then
    echo "warning: $sock missing — start Xvfb (or your virtual framebuffer) for DISPLAY=$d before wine runs." >&2
  fi
}

# Default: /opt/vara/wineprefixes/vara (32-bit Windows personality).
default_wine_prefix() {
  echo "${VARA_ROOT}/wineprefixes/vara"
}

prepare_vara_opt_dirs() {
  sudo mkdir -p "${VARA_ROOT}/config" "${VARA_ROOT}/libexec" "${VARA_ROOT}/installers" "${VARA_ROOT}/logs" "${VARA_ROOT}/profiles" "${VARA_ROOT}/wineprefixes"
  sudo chown "${TARGET_USER}:${TARGET_USER}" "${VARA_ROOT}/libexec" "${VARA_ROOT}/installers" "${VARA_ROOT}/logs" "${VARA_ROOT}/profiles" "${VARA_ROOT}/wineprefixes"
  sudo chmod 755 "${VARA_ROOT}/libexec" "${VARA_ROOT}/installers" "${VARA_ROOT}/logs" "${VARA_ROOT}/profiles" "${VARA_ROOT}/wineprefixes"
}

write_wine_env_file() {
  local prefix=$1
  local display=$2
  local envfile=$VARA_WINE_ENV_FILE
  sudo mkdir -p "${VARA_ROOT}/config"
  {
    echo "# VARA / 32-bit Wine — created by setup-wine-for-vara.sh"
    printf 'export WINEPREFIX=%q\n' "$prefix"
    echo "export WINEARCH=win32"
    printf 'export DISPLAY=%q\n' "$display"
  } | sudo tee "$envfile" >/dev/null
  sudo chown "${TARGET_USER}:${TARGET_USER}" "$envfile"
  sudo chmod 600 "$envfile"
  echo "Wrote $envfile"
}

ensure_shell_hook() {
  local rc=${TARGET_HOME}/.bashrc
  [[ -f "$rc" ]] || return 0
  if sudo -u "$TARGET_USER" grep -qF "/opt/vara/config/wine.env" "$rc" 2>/dev/null ||
    sudo -u "$TARGET_USER" grep -qF ".config/vara/wine.env" "$rc" 2>/dev/null; then
    echo "~/.bashrc already references VARA wine.env"
    return 0
  fi
  echo "Appending VARA wine env hook to ~/.bashrc"
  sudo -u "$TARGET_USER" tee -a "$rc" >/dev/null <<EOF

$MARK_BEGIN
[ -f ${VARA_WINE_ENV_FILE} ] && . ${VARA_WINE_ENV_FILE}
$MARK_END
EOF
}

# wineboot --init often returns before the prefix is fully written (especially Wine 9+).
wait_for_system_reg() {
  local prefix=$1 max_sec=$2
  local i
  for ((i = 0; i < max_sec; i++)); do
    sudo -u "$TARGET_USER" test -f "$prefix/system.reg" && return 0
    sleep 1
  done
  return 1
}

init_wine_prefix() {
  local prefix=$1
  local wb_rc

  if sudo -u "$TARGET_USER" test -f "$prefix/system.reg"; then
    echo "Wine prefix already exists at $prefix (skipping wineboot --init)."
    return 0
  fi

  echo "Creating 32-bit Wine prefix at $prefix (this may take a minute)..."
  # WINEDEBUG=-all cuts OLE/setupapi noise; real failures surface via exit codes and missing system.reg.
  set +e
  sudo -u "$TARGET_USER" env \
    DISPLAY="$WINE_DISPLAY" \
    WINEARCH=win32 \
    WINEPREFIX="$prefix" \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINEDEBUG=-all \
    wineboot --init
  wb_rc=$?
  set -e

  if [[ "$wb_rc" -ne 0 ]]; then
    die "wineboot --init exited with status $wb_rc — check DISPLAY=$WINE_DISPLAY (e.g. sudo systemctl status xvfb) and that user $TARGET_USER can use that display"
  fi

  echo "Waiting for Wine server (wineserver -w)..."
  sudo -u "$TARGET_USER" env \
    DISPLAY="$WINE_DISPLAY" \
    WINEARCH=win32 \
    WINEPREFIX="$prefix" \
    WINEDEBUG=-all \
    wineserver -w 2>/dev/null || true

  # One synchronous process load often flushes registry files after --init returns early.
  sudo -u "$TARGET_USER" env \
    DISPLAY="$WINE_DISPLAY" \
    WINEARCH=win32 \
    WINEPREFIX="$prefix" \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINEDEBUG=-all \
    wine cmd /c exit 0 2>/dev/null || true

  if wait_for_system_reg "$prefix" 120; then
    echo "Wine prefix ready at $prefix."
    return 0
  fi

  echo "system.reg not ready yet; running wineboot -u once..."
  set +e
  sudo -u "$TARGET_USER" env \
    DISPLAY="$WINE_DISPLAY" \
    WINEARCH=win32 \
    WINEPREFIX="$prefix" \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINEDEBUG=-all \
    wineboot -u
  wb_rc=$?
  set -e
  [[ "$wb_rc" -eq 0 ]] || echo "warning: wineboot -u exited with status $wb_rc (continuing)" >&2

  sudo -u "$TARGET_USER" env \
    DISPLAY="$WINE_DISPLAY" \
    WINEARCH=win32 \
    WINEPREFIX="$prefix" \
    WINEDEBUG=-all \
    wineserver -w 2>/dev/null || true

  if wait_for_system_reg "$prefix" 90; then
    echo "Wine prefix ready at $prefix (after wineboot -u)."
    return 0
  fi

  die "Wine never created $prefix/system.reg after wineboot --init. Is Xvfb (or X) running on $WINE_DISPLAY? Try: sudo systemctl start xvfb. If this was a partial run, remove the broken prefix and retry: rm -rf $(printf '%q' "$prefix")"
}

# Extra DLLs / runtime VARA often needs (.NET 3.5 SP1 is large; may take many minutes).
run_winetricks_vara_extras() {
  local prefix=$1
  local stamp=${prefix}/${WINETRICKS_STAMP}

  sudo -u "$TARGET_USER" test -f "$prefix/system.reg" ||
    die "Wine prefix missing at $prefix/system.reg — remove broken prefix and re-run this script: rm -rf $(printf '%q' "$prefix")"

  if sudo -u "$TARGET_USER" test -f "$stamp"; then
    echo "winetricks VARA extras already applied (remove $prefix/$WINETRICKS_STAMP to re-run)."
    return 0
  fi

  echo "Running winetricks --unattended winxp sound=alsa dotnet35sp1 vb6run (this can take a long time)..."
  sudo -u "$TARGET_USER" env \
    DISPLAY="$WINE_DISPLAY" \
    WINEARCH=win32 \
    WINEPREFIX="$prefix" \
    winetricks --unattended winxp sound=alsa dotnet35sp1 vb6run

  sudo -u "$TARGET_USER" touch "$stamp"
}

usage() {
  cat <<'USAGE'
Install Wine + winetricks and a 32-bit prefix for VARA on Debian.
Run as a normal user (uses sudo for apt). See script header for details.
USAGE
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

  require_debian
  [[ $EUID -eq 0 && -z "${SUDO_USER:-}" ]] &&
    die "run as a normal user (not a root login); sudo is only used for apt/source changes"

  have_sudo
  resolve_target_user
  resolve_wine_display
  warn_if_no_x_socket "$WINE_DISPLAY"

  local prefix
  prefix=$(default_wine_prefix)

  enable_contrib_sources_list
  enable_contrib_debian_sources
  add_i386
  apt_install_wine_stack

  sudo -u "$TARGET_USER" mkdir -p "$(dirname "$prefix")"
  prepare_vara_opt_dirs
  write_wine_env_file "$prefix" "$WINE_DISPLAY"
  ensure_shell_hook
  init_wine_prefix "$prefix"
  run_winetricks_vara_extras "$prefix"

  echo
  echo "Done."
  echo "  WINEPREFIX=$prefix"
  echo "  WINEARCH=win32"
  echo "  DISPLAY=$WINE_DISPLAY"
  echo "  Load env:  source ${VARA_WINE_ENV_FILE}"
  echo "  Next: ./download-vara-installers.sh then ./install-vara.sh (from this repo, as this user)"
}

main "$@"
