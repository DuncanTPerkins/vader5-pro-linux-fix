#!/usr/bin/env bash
# Install the SDL HIDAPI Vader 5 Pro override for Steam.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "[err ] do NOT run this script with sudo." >&2
    echo "       It installs into your \$HOME. Re-run as your own user." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"

SDL_REF="${SDL_REF:-release-3.4.4}"
SDL_SRC="${SDL_SRC:-$HOME/sdl-build/SDL-3.4.4}"
SDL_REPO_URL="https://github.com/libsdl-org/SDL.git"

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
SDL_DEPLOY_DIR="$DEPLOY_DIR/sdl"
WRAPPER_DST="$DEPLOY_DIR/wrapper.sh"
UDEV_RULE_SRC="$REPO_ROOT/60-vader5-sdl.rules"
UDEV_RULE_DST="/etc/udev/rules.d/60-vader5-sdl.rules"
PATCH_FILE="$REPO_ROOT/sdl-flydigi-vader5-linux.patch"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err ]${NC} $*" >&2; }

# ── Distro + package manager detection ───────────────────────────────────────

PKG_MANAGER=""
PKG_INSTALL=""
PKG_CONFIG_32=""
X11_32_LIB=""
X11_INCLUDE=""

detect_env() {
    if command -v pacman &>/dev/null; then
        PKG_MANAGER=pacman
        PKG_INSTALL="sudo pacman -S --needed --noconfirm"
        PKG_CONFIG_32="/usr/lib32/pkgconfig"
        X11_32_LIB="/usr/lib32/libX11.so"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER=dnf
        PKG_INSTALL="sudo dnf install -y"
        if [[ -d /usr/lib32/pkgconfig ]]; then
            PKG_CONFIG_32="/usr/lib32/pkgconfig"
            X11_32_LIB="/usr/lib32/libX11.so"
        else
            PKG_CONFIG_32="/usr/lib/pkgconfig"
            X11_32_LIB="/usr/lib/libX11.so"
        fi
    elif command -v apt-get &>/dev/null; then
        PKG_MANAGER=apt
        PKG_INSTALL="sudo apt-get install -y"
        PKG_CONFIG_32="/usr/lib/i386-linux-gnu/pkgconfig"
        X11_32_LIB="/usr/lib/i386-linux-gnu/libX11.so"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER=zypper
        PKG_INSTALL="sudo zypper install -y"
        PKG_CONFIG_32="/usr/lib/pkgconfig"
        X11_32_LIB="/usr/lib32/libX11.so"
    else
        warn "Unknown package manager — you may need to install build deps manually"
    fi

    if [[ -d /usr/include/X11 ]]; then
        X11_INCLUDE="/usr/include"
    fi

    if [[ -n "$X11_32_LIB" && ! -f "$X11_32_LIB" ]]; then
        local found
        found="$(ldconfig -p 2>/dev/null \
            | awk '/libX11\.so.*ELF32|libX11\.so.*i386/{print $NF; exit}')"
        [[ -n "$found" ]] && X11_32_LIB="$found"
    fi

    if [[ -n "$PKG_MANAGER" ]]; then
        info "Detected package manager: $PKG_MANAGER"
    fi
}

# ── Steam launcher detection ──────────────────────────────────────────────────

STEAM_LAUNCHER=""

detect_steam() {
    for p in \
        /usr/lib/steamos/steam-launcher \
        /usr/bin/steam \
        /usr/games/steam \
        "$HOME/.local/share/Steam/steam.sh"; do
        if [[ -x "$p" ]]; then
            STEAM_LAUNCHER="$p"
            ok "Steam launcher: $STEAM_LAUNCHER"
            return
        fi
    done

    if flatpak list 2>/dev/null | grep -q 'com.valvesoftware.Steam'; then
        err "Flatpak Steam detected. This script does not support Flatpak Steam."
        err "Install Steam as a native package or use the standalone installer."
        exit 1
    fi

    err "Cannot find Steam. Install Steam and re-run."
    exit 1
}

# ── Wiring mode detection ─────────────────────────────────────────────────────
# service: override steam-launcher.service (SteamOS / Bazzite game mode)
# desktop: override ~/.local/share/applications/steam.desktop (everywhere else)

WIRE_MODE=""
STEAM_DESKTOP_SRC=""

detect_wiring_mode() {
    if systemctl --user cat steam-launcher.service &>/dev/null; then
        WIRE_MODE=service
        info "Wiring mode: systemd service (steam-launcher.service)"
        return
    fi

    for p in \
        /usr/share/applications/steam.desktop \
        /usr/lib/steam/steam.desktop \
        /usr/local/share/applications/steam.desktop; do
        if [[ -f "$p" ]]; then
            STEAM_DESKTOP_SRC="$p"
            WIRE_MODE=desktop
            info "Wiring mode: .desktop override (source: $p)"
            return
        fi
    done

    if [[ -n "$STEAM_LAUNCHER" ]]; then
        WIRE_MODE=desktop
        warn "No system steam.desktop found; will create a minimal one"
        return
    fi

    err "Cannot determine how to wire Steam. Report this at the project repo."
    exit 1
}

# ── Prerequisites check ───────────────────────────────────────────────────────

MISSING_TOOLS=()

check_tool() {
    command -v "$1" &>/dev/null || MISSING_TOOLS+=("$1")
}

install_deps() {
    [[ ${#MISSING_TOOLS[@]} -eq 0 ]] && return

    warn "Missing tools: ${MISSING_TOOLS[*]}"

    if [[ -z "$PKG_MANAGER" ]]; then
        err "Cannot auto-install — install the missing tools manually and re-run."
        exit 1
    fi

    local pkgs=()
    case "$PKG_MANAGER" in
        pacman)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)   pkgs+=(cmake) ;;
                    ninja)   pkgs+=(ninja) ;;
                    git)     pkgs+=(git) ;;
                    patch)   pkgs+=(patch) ;;
                    gcc)     pkgs+=(gcc gcc-multilib) ;;
                    bwrap)   pkgs+=(bubblewrap) ;;
                esac
            done
            ;;
        dnf)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)   pkgs+=(cmake) ;;
                    ninja)   pkgs+=(ninja-build) ;;
                    git)     pkgs+=(git) ;;
                    patch)   pkgs+=(patch) ;;
                    gcc)     pkgs+=(gcc glibc-devel.i686 libstdc++-devel.i686) ;;
                    bwrap)   pkgs+=(bubblewrap) ;;
                esac
            done
            ;;
        apt)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)   pkgs+=(cmake) ;;
                    ninja)   pkgs+=(ninja-build) ;;
                    git)     pkgs+=(git) ;;
                    patch)   pkgs+=(patch) ;;
                    gcc)     pkgs+=(gcc gcc-multilib) ;;
                    bwrap)   pkgs+=(bubblewrap) ;;
                esac
            done
            ;;
        zypper)
            for t in "${MISSING_TOOLS[@]}"; do
                case "$t" in
                    cmake)   pkgs+=(cmake) ;;
                    ninja)   pkgs+=(ninja) ;;
                    git)     pkgs+=(git) ;;
                    patch)   pkgs+=(patch) ;;
                    gcc)     pkgs+=(gcc gcc-32bit) ;;
                    bwrap)   pkgs+=(bubblewrap) ;;
                esac
            done
            ;;
    esac

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        info "Installing: ${pkgs[*]}"
        $PKG_INSTALL "${pkgs[@]}"
    fi
}

install_x11_32() {
    # Only needed for the 32-bit SDL cmake build
    if [[ -n "$X11_32_LIB" && -f "$X11_32_LIB" ]]; then
        return
    fi

    warn "32-bit libX11 not found at $X11_32_LIB"
    [[ -z "$PKG_MANAGER" ]] && { err "Install 32-bit X11 dev libs manually and re-run."; exit 1; }

    case "$PKG_MANAGER" in
        pacman)  $PKG_INSTALL lib32-libx11 lib32-libxext lib32-glibc lib32-gcc-libs ;;
        dnf)     $PKG_INSTALL libX11-devel.i686 libXext-devel.i686 glibc-devel.i686 ;;
        apt)     sudo dpkg --add-architecture i386 2>/dev/null || true
                 sudo apt-get update -qq
                 $PKG_INSTALL libx11-dev:i386 libxext-dev:i386 ;;
        zypper)  $PKG_INSTALL libX11-devel-32bit ;;
    esac

    # Re-probe after install
    if [[ ! -f "$X11_32_LIB" ]]; then
        local found
        found="$(ldconfig -p 2>/dev/null \
            | awk '/libX11\.so.*ELF32|libX11\.so.*i386/{print $NF; exit}')"
        [[ -n "$found" ]] && X11_32_LIB="$found"
    fi
}

# ── SDL cmake flags ───────────────────────────────────────────────────────────
# Minimal Steam-client profile: video + X11 + OpenGL for the client UI,
# HIDAPI + joystick for controller support, everything else off.
# MinSizeRel + strip keeps the library well under Steam's original file sizes.
# RUNPATH=$ORIGIN matches what Valve ships so Steam's module loader is happy.

SDL_CMAKE_COMMON=(
    -GNinja
    -DCMAKE_BUILD_TYPE=MinSizeRel
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    "-DCMAKE_INSTALL_RPATH=\$ORIGIN"
    -DCMAKE_SKIP_BUILD_RPATH=OFF
    -DBUILD_SHARED_LIBS=ON
    -DSDL_SHARED=ON -DSDL_STATIC=OFF
    -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF
    -DSDL_INSTALL_TESTS=OFF -DSDL_INSTALL_DOCS=OFF
    -DSDL_AUDIO=OFF -DSDL_CAMERA=OFF -DSDL_DIALOG=OFF
    -DSDL_GPU=OFF -DSDL_KMSDRM=OFF -DSDL_OFFSCREEN=OFF
    -DSDL_OPENGLES=OFF -DSDL_PIPEWIRE=OFF -DSDL_PULSEAUDIO=OFF
    -DSDL_SNDIO=OFF -DSDL_WAYLAND=OFF -DSDL_TRAY=OFF -DSDL_VULKAN=OFF
    -DSDL_DBUS=OFF -DSDL_IBUS=OFF -DSDL_FRIBIDI=OFF -DSDL_LIBTHAI=OFF
    -DSDL_JACK=OFF -DSDL_ALSA=OFF
    -DSDL_HAPTIC=ON -DSDL_SENSOR=ON
    -DSDL_HIDAPI=ON -DSDL_HIDAPI_JOYSTICK=ON -DSDL_HIDAPI_LIBUSB=ON
    -DSDL_JOYSTICK=ON -DSDL_VIRTUAL_JOYSTICK=ON
    -DSDL_VIDEO=ON -DSDL_RENDER=ON -DSDL_OPENGL=ON
    -DSDL_X11=ON -DSDL_X11_SHARED=ON
)

# ── Build helpers ─────────────────────────────────────────────────────────────

_verify_sdl() {
    local lib="$1" bits="$2"
    if ! readelf -d "$lib" 2>/dev/null | grep -q 'RUNPATH.*\$ORIGIN'; then
        warn "$lib is missing RUNPATH=\$ORIGIN — Steam's loader may not handle it correctly"
    fi
    local class
    class="$(readelf -h "$lib" 2>/dev/null | awk '/Class:/{print $2}')"
    if [[ "$bits" == "32" && "$class" != "ELF32" ]]; then
        err "$lib is $class, expected ELF32"
        exit 1
    fi
    if [[ "$bits" == "64" && "$class" != "ELF64" ]]; then
        err "$lib is $class, expected ELF64"
        exit 1
    fi
}

_find_sdl_versioned() {
    find "$1" -maxdepth 1 -name 'libSDL3.so.0.*' | head -1
}

# ── Wiring functions ──────────────────────────────────────────────────────────

wire_service() {
    local override_dir="$HOME/.config/systemd/user/steam-launcher.service.d"
    mkdir -p "$override_dir"
    cat > "$override_dir/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=$WRAPPER_DST
EOF
    systemctl --user daemon-reload
    ok "Systemd override installed: $override_dir/override.conf"
}

wire_desktop() {
    local dst="$HOME/.local/share/applications/steam.desktop"
    mkdir -p "$(dirname "$dst")"

    if [[ -n "$STEAM_DESKTOP_SRC" ]]; then
        awk -v wrapper="$WRAPPER_DST" '
            /^\[/ { in_entry = ($0 == "[Desktop Entry]") }
            in_entry && /^Exec=/ { print "Exec=" wrapper " %U"; next }
            { print }
        ' "$STEAM_DESKTOP_SRC" > "$dst"
    else
        cat > "$dst" <<EOF
[Desktop Entry]
Name=Steam
Comment=Application for managing and playing games on Steam
Exec=$WRAPPER_DST %U
Icon=steam
Terminal=false
Type=Application
Categories=Network;FileTransfer;Game;
MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;
StartupWMClass=Steam
EOF
    fi

    ok ".desktop override installed: $dst"
    info "The wrapper will be used when Steam is launched from your app menu."
    info "To launch from terminal: $WRAPPER_DST"
}

# ── Main ──────────────────────────────────────────────────────────────────────

detect_env
detect_steam
detect_wiring_mode

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites"

check_tool gcc
check_tool cmake
check_tool ninja
check_tool git
check_tool bwrap
check_tool patch

install_deps

if ! echo 'int main(){}' | gcc -m32 -x c - -o /dev/null 2>/dev/null; then
    warn "gcc -m32 not working — 32-bit SDL build may fail"
    case "${PKG_MANAGER:-}" in
        pacman) warn "Try: sudo pacman -S --needed gcc-multilib lib32-glibc lib32-gcc-libs" ;;
        dnf)    warn "Try: sudo dnf install -y glibc-devel.i686 libstdc++-devel.i686" ;;
        apt)    warn "Try: sudo apt-get install -y gcc-multilib" ;;
    esac
fi
ok "Prerequisites satisfied"

# ── 2. SDL source ─────────────────────────────────────────────────────────────
info "SDL source: $SDL_SRC"

if [[ ! -d "$SDL_SRC/.git" ]]; then
    info "Cloning SDL $SDL_REF into $SDL_SRC"
    mkdir -p "$(dirname "$SDL_SRC")"
    git clone --quiet --branch "$SDL_REF" --depth 1 "$SDL_REPO_URL" "$SDL_SRC"
    ok "SDL cloned"
else
    info "SDL source already present at $SDL_SRC"
fi

# Apply patch if the key symbol isn't already there
if grep -q 'SDL_HIDAPI_Flydigi_UsesUnnumbered32ByteReports' \
        "$SDL_SRC/src/joystick/hidapi/SDL_hidapi_flydigi.c" 2>/dev/null; then
    ok "Flydigi Linux patch already applied"
else
    info "Applying Flydigi Linux patch"
    if ! patch -N -p1 -d "$SDL_SRC" < "$PATCH_FILE"; then
        err "Patch failed to apply. The SDL source may be at a different version."
        err "Check $PATCH_FILE against $SDL_SRC/src/joystick/hidapi/SDL_hidapi_flydigi.c"
        exit 1
    fi
    ok "Patch applied"
fi

# ── 3. Build 64-bit SDL ───────────────────────────────────────────────────────
SDL_BUILD64="$SDL_SRC/build-steam64"

if [[ -f "$SDL_BUILD64/libSDL3.so.0" ]]; then
    ok "64-bit SDL build already present at $SDL_BUILD64"
else
    info "Configuring 64-bit SDL (build dir: $SDL_BUILD64)"
    cmake -S "$SDL_SRC" -B "$SDL_BUILD64" \
        "${SDL_CMAKE_COMMON[@]}" \
        > /tmp/sdl-cmake64.log 2>&1 \
        || { err "cmake 64-bit failed — see /tmp/sdl-cmake64.log"; exit 1; }

    info "Building 64-bit SDL (this takes a few minutes)"
    cmake --build "$SDL_BUILD64" -j"$(nproc)" \
        > /tmp/sdl-build64.log 2>&1 \
        || { err "build 64-bit failed — see /tmp/sdl-build64.log"; exit 1; }
    ok "64-bit SDL built"
fi

# ── 4. Build 32-bit SDL ───────────────────────────────────────────────────────
SDL_BUILD32="$SDL_SRC/build-steam32"

install_x11_32

if [[ -f "$SDL_BUILD32/libSDL3.so.0" ]]; then
    ok "32-bit SDL build already present at $SDL_BUILD32"
else
    info "Configuring 32-bit SDL (build dir: $SDL_BUILD32)"

    CMAKE_32_EXTRA=(
        "-DCMAKE_C_FLAGS=-m32"
        "-DCMAKE_CXX_FLAGS=-m32"
        "-DCMAKE_EXE_LINKER_FLAGS=-m32"
        "-DCMAKE_SHARED_LINKER_FLAGS=-m32"
    )

    # X11 library hints for cross-compile to 32-bit
    if [[ -n "$X11_32_LIB" && -f "$X11_32_LIB" ]]; then
        CMAKE_32_EXTRA+=(
            "-DX11_LIB=$X11_32_LIB"
            "-DX11_X11_LIB=$X11_32_LIB"
        )
    fi
    if [[ -n "$X11_INCLUDE" ]]; then
        CMAKE_32_EXTRA+=("-DX11_INCLUDEDIR=$X11_INCLUDE")
    fi

    PKG_CONFIG_CMD=""
    if [[ -n "$PKG_CONFIG_32" && -d "$PKG_CONFIG_32" ]]; then
        PKG_CONFIG_CMD="PKG_CONFIG_LIBDIR=$PKG_CONFIG_32"
    fi

    env $PKG_CONFIG_CMD cmake -S "$SDL_SRC" -B "$SDL_BUILD32" \
        "${SDL_CMAKE_COMMON[@]}" \
        "${CMAKE_32_EXTRA[@]}" \
        > /tmp/sdl-cmake32.log 2>&1 \
        || { err "cmake 32-bit failed — see /tmp/sdl-cmake32.log"; exit 1; }

    info "Building 32-bit SDL (this takes a few minutes)"
    cmake --build "$SDL_BUILD32" -j"$(nproc)" \
        > /tmp/sdl-build32.log 2>&1 \
        || { err "build 32-bit failed — see /tmp/sdl-build32.log"; exit 1; }
    ok "32-bit SDL built"
fi

# Locate versioned .so files and verify them
SDL64_VERSIONED="$(_find_sdl_versioned "$SDL_BUILD64")"
SDL32_VERSIONED="$(_find_sdl_versioned "$SDL_BUILD32")"

[[ -n "$SDL64_VERSIONED" ]] || { err "64-bit SDL .so not found in $SDL_BUILD64"; exit 1; }
[[ -n "$SDL32_VERSIONED" ]] || { err "32-bit SDL .so not found in $SDL_BUILD32"; exit 1; }

_verify_sdl "$SDL64_VERSIONED" 64
_verify_sdl "$SDL32_VERSIONED" 32

# ── 5. Deploy patched SDL ─────────────────────────────────────────────────────
info "Deploying patched SDL to $SDL_DEPLOY_DIR"
mkdir -p "$SDL_DEPLOY_DIR"

install -m 755 "$SDL64_VERSIONED" "$SDL_DEPLOY_DIR/libSDL3-64.so.0"
install -m 755 "$SDL32_VERSIONED" "$SDL_DEPLOY_DIR/libSDL3-32.so.0"

strip --strip-unneeded "$SDL_DEPLOY_DIR/libSDL3-64.so.0" 2>/dev/null || true
strip --strip-unneeded "$SDL_DEPLOY_DIR/libSDL3-32.so.0" 2>/dev/null || true

ok "SDL deployed"

# ── 6. Deploy bwrap wrapper ───────────────────────────────────────────────────
info "Deploying bwrap wrapper"
mkdir -p "$DEPLOY_DIR"

cat > "$WRAPPER_DST" <<'WRAPPER_EOF'
#!/bin/bash
SDL32="$HOME/.local/share/vader5-driver/sdl/libSDL3-32.so.0"
SDL64="$HOME/.local/share/vader5-driver/sdl/libSDL3-64.so.0"
STEAM32="$HOME/.local/share/Steam/ubuntu12_32/libSDL3.so.0"
STEAM64="$HOME/.local/share/Steam/ubuntu12_64/libSDL3.so.0"
STEAM_LAUNCHER="@@STEAM_LAUNCHER@@"

BWRAP="$(command -v bwrap 2>/dev/null)"
if [[ -z "$BWRAP" ]]; then
    echo "vader5-driver wrapper: bwrap not found — install bubblewrap" >&2
    exit 1
fi

if [[ ! -x "$STEAM_LAUNCHER" ]]; then
    echo "vader5-driver wrapper: missing Steam launcher: $STEAM_LAUNCHER" >&2
    exit 1
fi

for _f in "$SDL32" "$SDL64"; do
    if [[ ! -f "$_f" ]]; then
        echo "vader5-driver wrapper: patched SDL not found: $_f" >&2
        echo "  Re-run: bash scripts/install.sh" >&2
        exit 1
    fi
done

export SDL_JOYSTICK_HIDAPI=1
unset SDL_GAMECONTROLLERCONFIG

exec "$BWRAP" \
    --bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --bind "$SDL32" "$STEAM32" \
    --bind "$SDL64" "$STEAM64" \
    -- "$STEAM_LAUNCHER" "$@"
WRAPPER_EOF

sed -i.bak "s|@@STEAM_LAUNCHER@@|$STEAM_LAUNCHER|g" "$WRAPPER_DST"
rm -f "$WRAPPER_DST.bak"

chmod 755 "$WRAPPER_DST"
ok "Wrapper deployed: $WRAPPER_DST"

# ── 7. Wire Steam ─────────────────────────────────────────────────────────────
info "Wiring Steam (mode: $WIRE_MODE)"

case "$WIRE_MODE" in
    service) wire_service ;;
    desktop) wire_desktop ;;
esac

# ── 8. Udev rule ──────────────────────────────────────────────────────────────
info "Installing udev rule"

OLD_PADCTL_RULE="/etc/udev/rules.d/60-padctl-vader5-userspace.rules"
if [[ -f "$OLD_PADCTL_RULE" ]]; then
    info "Disabling old padctl udev rule"
    sudo mv "$OLD_PADCTL_RULE" "${OLD_PADCTL_RULE}.disabled" \
        || warn "Could not disable old padctl rule — remove it manually if present"
fi

sudo install -m 644 "$UDEV_RULE_SRC" "$UDEV_RULE_DST"
sudo udevadm control --reload-rules
sudo udevadm trigger
ok "Udev rule installed"

# ── 9. Restart Steam ──────────────────────────────────────────────────────────
if [[ "$WIRE_MODE" == "service" ]] \
        && systemctl --user is-active steam-launcher.service &>/dev/null; then
    info "Restarting steam-launcher.service"
    systemctl --user restart steam-launcher.service
    ok "Steam restarted"
elif [[ "$WIRE_MODE" == "service" ]]; then
    warn "steam-launcher.service is not running — start Steam to apply the override"
else
    warn "Close and reopen Steam from your app menu for the .desktop override to take effect"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
ok "Installation complete."
echo ""
echo "  Patched SDL:  $SDL_DEPLOY_DIR/"
echo "  Wrapper:      $WRAPPER_DST"
echo "  Udev rule:    $UDEV_RULE_DST"
case "$WIRE_MODE" in
    service) echo "  Systemd:      $HOME/.config/systemd/user/steam-launcher.service.d/override.conf" ;;
    desktop) echo "  Desktop:      $HOME/.local/share/applications/steam.desktop" ;;
esac
echo ""
echo "Next steps:"
echo "  1. Replug the Vader 5 Pro (or reconnect the 2.4G dongle) so the new"
echo "     udev rule fires and unbinds xpad from interface 0."
echo "  2. In Steam: Settings → Controller → Detected Controllers."
echo "     The device should now appear as 'Flydigi Vader 5 Pro' (or similar)"
echo "     rather than 'Generic X-Box pad'."
echo "  3. If it still shows as Xbox, check the logs:"
echo "     journalctl --user -u steam-launcher.service -n 50  (service mode)"
echo "     grep -n 'Flydigi\|Vader\|HIDAPI' ~/.local/share/Steam/logs/controller.txt"
