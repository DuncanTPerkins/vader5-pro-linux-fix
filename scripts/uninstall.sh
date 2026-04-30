#!/usr/bin/env bash
# uninstall.sh — remove the SDL HIDAPI Vader 5 Pro override
#
# Removes whichever wiring the install script created:
#   - steam-launcher.service.d override.conf  (service mode)
#   - ~/.local/share/applications/steam.desktop  (desktop mode, if ours)
#   - /etc/udev/rules.d/60-vader5-sdl.rules
#   - ~/.local/share/vader5-driver/sdl/   (patched SDL)
#   - ~/.local/share/vader5-driver/wrapper.sh
#
# Does NOT remove SDL source or build dirs under ~/sdl-build/SDL.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "[err ] do NOT run this script with sudo." >&2
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
OVERRIDE="$HOME/.config/systemd/user/steam-launcher.service.d/override.conf"
USER_DESKTOP="$HOME/.local/share/applications/steam.desktop"

# Service mode wiring
if [[ -f "$OVERRIDE" ]]; then
    rm -f "$OVERRIDE"
    systemctl --user daemon-reload
    ok "Removed systemd override"

    if systemctl --user is-active steam-launcher.service &>/dev/null; then
        info "Restarting Steam without override"
        systemctl --user restart steam-launcher.service
    fi
fi

# Desktop mode wiring — only remove if it was created by us (contains our wrapper path)
if [[ -f "$USER_DESKTOP" ]] \
        && grep -q "vader5-driver" "$USER_DESKTOP" 2>/dev/null; then
    rm -f "$USER_DESKTOP"
    ok "Removed .desktop override"
fi

# Udev rule
if [[ -f "/etc/udev/rules.d/60-vader5-sdl.rules" ]]; then
    sudo rm -f "/etc/udev/rules.d/60-vader5-sdl.rules"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    ok "Removed udev rule"
fi

# Deployed artifacts
rm -rf "$DEPLOY_DIR/sdl"
rm -f "$DEPLOY_DIR/wrapper.sh"
# Remove artifacts from older installs if present
rm -f "$DEPLOY_DIR/steam-sdl-wrapper.sh" "$DEPLOY_DIR/sdl_intercept32.so" "$DEPLOY_DIR/sdl_intercept64.so"
ok "Removed deployed SDL and wrapper"

ok "Uninstall complete. Replug the controller to restore default xpad binding."
