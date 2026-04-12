#!/usr/bin/env bash
# Install common headless/server packages and systemd Xvfb on :1 (user ham).
# Run as a user with sudo. Targets Debian (apt).

set -euo pipefail

readonly XVFB_UNIT=/etc/systemd/system/xvfb.service

die() {
  echo "error: $*" >&2
  exit 1
}

require_sudo() {
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  sudo -n true 2>/dev/null || {
    echo "This script needs sudo for apt and systemd."
    sudo true
  }
}

require_debian_apt() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found (Debian/Ubuntu only)"
}

ensure_user_ham() {
  getent passwd ham >/dev/null 2>&1 ||
    die "Linux user 'ham' must exist before Xvfb can run as User=ham (e.g. sudo adduser ham)"
}

# VARA runtime data lives under /opt/vara (not ~/vara) so ham's home stays free of service files.
setup_opt_vara_tree() {
  local r=/opt/vara
  echo "Creating $r layout (root-owned bin/config/scripts; ham-owned data dirs)..."
  sudo mkdir -p "$r"/{bin,config,scripts,libexec,installers,logs,profiles,wineprefixes}
  sudo chown root:root "$r/bin" "$r/config" "$r/scripts"
  sudo chmod 755 "$r/bin" "$r/config" "$r/scripts"
  sudo chown -R ham:ham "$r/libexec" "$r/installers" "$r/logs" "$r/profiles" "$r/wineprefixes"
  sudo chmod 755 "$r/libexec" "$r/installers" "$r/logs" "$r/profiles" "$r/wineprefixes"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  echo "Running apt-get update..."
  sudo apt-get update -y
  echo "Installing packages..."
  sudo apt-get install -y \
    sudo \
    vim \
    tmux \
    curl \
    wget \
    git \
    openssh-server \
    avahi-daemon \
    xauth \
    x11-utils \
    xvfb \
    dnsmasq \
    hostapd \
    iw \
    iproute2 \
    alsa-utils \
    golang-go \
    libhamlib-utils \
    jq
}

install_xvfb_unit() {
  echo "Writing $XVFB_UNIT"
  sudo tee "$XVFB_UNIT" >/dev/null <<'UNIT'
[Unit]
Description=Virtual X framebuffer
After=network.target

[Service]
User=ham
Environment=DISPLAY=:1
ExecStart=/usr/bin/Xvfb :1 -screen 0 1280x800x24 -nolisten tcp
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
}

enable_xvfb() {
  sudo systemctl daemon-reload
  sudo systemctl enable xvfb
  sudo systemctl start xvfb
  sudo systemctl --no-pager --full status xvfb || true
}

usage() {
  cat <<'USAGE'
Install apt prerequisites and Xvfb systemd service (DISPLAY :1, user ham).
Requires: existing local user 'ham'. Run: ./setup-headless-prereqs.sh
USAGE
}

main() {
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

  require_sudo
  require_debian_apt
  ensure_user_ham
  setup_opt_vara_tree

  install_packages
  install_xvfb_unit
  enable_xvfb

  echo
  echo "Done. Xvfb should be listening on DISPLAY=:1 (socket /tmp/.X11-unix/X1)."
  echo "Check: sudo systemctl status xvfb"
  echo "If you edit $XVFB_UNIT later: sudo systemctl daemon-reload && sudo systemctl restart xvfb"
  echo "VARA paths: /opt/vara/{config/wine.env,libexec,installers,logs,profiles,wineprefixes/vara} (see README)."
}

main "$@"
