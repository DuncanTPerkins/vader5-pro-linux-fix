# Flydigi Vader 5 Pro — native SDL HIDAPI on Linux

Makes Steam detect the Vader 5 Pro natively via SDL's Flydigi HIDAPI driver, giving full access to M1–M4, LM, RM, C, Z, and the rest of the extended button surface without a userspace daemon or virtual controller.

## Install

```sh
bash scripts/install.sh
```

Clones SDL3, applies the patch, builds 32+64-bit SDL, deploys everything, and wires Steam to use it. After it finishes, replug the controller. In Steam → Settings → Controller → Detected Controllers the device should appear as **Flydigi Vader 5 Pro** with the full button set visible in Steam Input.

To uninstall: `bash scripts/uninstall.sh`

## Compatibility

Works on SteamOS / Steam Deck, Bazzite, Arch, CachyOS, Fedora, Ubuntu, Debian, and any distro running native Steam. The install script detects your environment and adapts:

| Environment | Steam wiring |
|---|---|
| SteamOS / Steam Deck (game mode), Bazzite | `steam-launcher.service.d` ExecStart override |
| Desktop installs (Arch, Fedora, Ubuntu, etc.) | `~/.local/share/applications/steam.desktop` override |

Package manager (pacman / dnf / apt / zypper) and 32-bit library paths are detected automatically. Missing build tools are offered for auto-install.

Flatpak Steam is not supported — install Steam as a native package or via the [Steam installer](https://store.steampowered.com/about/).

## How it works

### The problem

The Vader 5 Pro exposes two USB interfaces:

| Interface | Driver | Protocol |
|---|---|---|
| 0 (XInput) | `xpad` kernel module | Standard Xbox HID report — 16 buttons, 6 axes |
| 1 (DInput / Flydigi) | SDL HIDAPI | Vendor-specific 32-byte report, unnumbered, magic `5a a5 ef …` |

All the extra inputs — M1–M4, LM, RM, C, Z, rumble — live on interface 1. Interface 0 knows nothing about them.

SDL3's Flydigi HIDAPI driver was written for earlier controllers (Vader 2 Pro, Vader 3 Pro) that use a *numbered* HID report on interface 1. The Vader 5 Pro switched to *unnumbered* 32-byte reports: same magic bytes and payload layout, but the leading report-ID byte is absent, so every offset is off by one. Without the fix, SDL can't parse the reports, falls back to interface 0 via `xpad`, and Steam sees a generic Xbox pad.

The upstream fix is not in the SDL build Steam currently ships on Linux, so this repo pins SDL `release-3.4.4` and applies the missing Linux-side Vader 5 Pro patch locally.

### Why you can't just replace Steam's SDL file

Steam runs a hash-based file verifier (`BVerifyInstalledFiles`) that detects any change to its bundled libraries and restores the originals within minutes. Three other approaches also fail:

- **LD_PRELOAD dlopen interceptor** — only catches explicit `dlopen()` calls. `steamui.so` declares SDL as a `NEEDED` compile-time dependency, so the dynamic linker resolves it at load time before any injected code runs. The hook is never called.
- **LD_LIBRARY_PATH prepend** — would work in principle (`steamui.so` uses `RUNPATH`, not `RPATH`, so `LD_LIBRARY_PATH` takes priority). But Steam's startup script unconditionally overwrites `LD_LIBRARY_PATH` with its own runtime directories before `steamui.so` loads, clobbering any value we set.
- **`unshare --user --mount --map-root-user`** — creates a private namespace where bind mounts work, but maps the process to uid=0 inside. Steam's bootstrap explicitly checks `id -u` and exits with "Cannot run as root user".

### The solution: bubblewrap

`bwrap` is a setuid-root namespace helper already installed on SteamOS (for Pressure Vessel) and available as a standard package everywhere else. It creates a private mount namespace while preserving the real uid — so uid=1000 stays uid=1000 inside the namespace and Steam starts normally.

The deployed `wrapper.sh` does:

```bash
exec bwrap \
    --bind / /                     \  # mirror the host tree
    --dev-bind /dev /dev           \  # device access (hidraw, input, DRI…)
    --proc /proc                   \  # /proc for Steam's self-inspection
    --bind "$SDL32" "$STEAM32"     \  # patched 32-bit SDL over Steam's copy
    --bind "$SDL64" "$STEAM64"     \  # patched 64-bit SDL over Steam's copy
    -- "$STEAM_LAUNCHER" "$@"
```

Inside the namespace, Steam's SDL paths resolve to our patched build. `steamui.so`'s `NEEDED: libSDL3.so.0` is satisfied by our SDL via `RUNPATH=$ORIGIN`. The host filesystem is never touched — the verifier has nothing to detect.

### What the patch changes

`sdl-flydigi-vader5-linux.patch` adds two things to `SDL_hidapi_flydigi.c`:

- **`SDL_HIDAPI_Flydigi_UsesUnnumbered32ByteReports()`** — returns true for Flydigi V2 devices on interface 1. Gates all adjusted read/write paths.
- **Adjusted packet handling** — `GetReply()` accepts 32-byte reads at offset 0 (no leading report-ID byte); `SDL_HIDAPI_Flydigi_WritePacket()` prepends a synthetic `0x00` report ID so `hid_write()` gets a correctly-shaped 33-byte buffer. Rumble output uses the same format.

Everything else — button mapping, paddle state, gyro parsing — is unchanged and already correct for the Vader 5 Pro's payload layout.

This repo is licensed under MIT. The included patch targets SDL, which is licensed upstream under zlib. If you redistribute patched SDL builds, preserve SDL's upstream notices as required by that project.

### xpad unbind

Without the udev rule, `xpad` binds to interface 0 and Steam sees two controllers: a generic Xbox pad alongside the Flydigi HIDAPI device. `60-vader5-sdl.rules` fires on device add, unbinds xpad from interface 0, and grants `hidraw` access so Steam can open interface 1 without root.

## File layout

```
~/sdl-build/SDL-3.4.4/                   # pinned SDL source
~/sdl-build/SDL-3.4.4/build-steam32/     # 32-bit patched SDL build
~/sdl-build/SDL-3.4.4/build-steam64/     # 64-bit patched SDL build

~/.local/share/vader5-driver/sdl/libSDL3-32.so.0   # deployed 32-bit SDL
~/.local/share/vader5-driver/sdl/libSDL3-64.so.0   # deployed 64-bit SDL
~/.local/share/vader5-driver/wrapper.sh             # bwrap launcher

# One of the following, depending on distro/setup:
~/.config/systemd/user/steam-launcher.service.d/override.conf
~/.local/share/applications/steam.desktop

/etc/udev/rules.d/60-vader5-sdl.rules
```

Nothing is written under `/usr`, `/usr/local`, or Steam's own file tree.

## Pre-flight

The install script offers to install missing build tools automatically. To install manually:

**Arch / SteamOS / CachyOS:**
```sh
sudo pacman -S --needed cmake ninja git patch gcc-multilib lib32-glibc lib32-gcc-libs bubblewrap
```

**Fedora / Bazzite:**
```sh
sudo dnf install -y cmake ninja-build git gcc patch glibc-devel.i686 libstdc++-devel.i686 bubblewrap
```

**Ubuntu / Debian:**
```sh
sudo apt-get install -y cmake ninja-build git gcc gcc-multilib patch bubblewrap
```

On SteamOS, run `passwd` first if you haven't set a sudo password.

## Survives updates?

Yes. The patched SDL and wrapper live in `~/.local/share/vader5-driver/` and the systemd or desktop wiring lives in `~/.config/` or `~/.local/share/applications/` — all of which persist across Steam updates and SteamOS A/B partition updates. The udev rule lives in `/etc/udev/rules.d/` which is overlayfs-backed on SteamOS. Steam's own files are never modified.

If Steam ships an SDL update that includes the fix natively, re-run the install script (it's idempotent) to rebuild and verify.

## FAQ

**Will the patched minimal SDL interfere with games, Vulkan, Wine Wayland, or HDR?**

No. This project replaces **Steam's client SDL**, not the SDL used by games.

- Games launched through Pressure Vessel use their own runtime container and their own SDL stack.
- Native Linux games that ship SDL usually bundle their own copy alongside the game.
- `SDL_VULKAN=OFF` in the patched build only affects the Steam client itself, which uses OpenGL for its UI.
- Wine's Wayland driver, HDR path, and game rendering stack do not depend on Steam's client SDL.
- Steam overlay rendering still works because the client build keeps the pieces Steam actually uses: `OpenGL`, `X11`, and `HIDAPI`.

In short: this patch should not block Vulkan games, Wine Wayland, or HDR, because it does not replace a system SDL or the SDL inside game runtimes.

**Is there any realistic VAC risk?**

Probably not.

- VAC targets game processes, memory tampering, hooks, and cheat signatures inside games.
- This project does not inject into game processes, preload into games, or modify game files.
- The only SDL being redirected is the Steam client's own SDL at `ubuntu12_32/libSDL3.so.0` and `ubuntu12_64/libSDL3.so.0`.
- The `bwrap` mount-namespace mechanism is the same class of tool Valve already uses for Pressure Vessel on Linux.

The risky approaches would have been things like `LD_PRELOAD` into games, code injection into running games, or modifying files inside a game's own runtime. This project does none of those.

**What has to change upstream for this project to become unnecessary?**

This project stops being necessary when the Linux stack handles the real controller correctly by default.

Required changes:

- **SDL must include the Vader 5 Pro Linux fix.** The Flydigi HIDAPI backend needs to handle the controller's interface-1 protocol correctly: unnumbered fixed-size 32-byte reports for input, status, and rumble/output writes.
- **Steam must ship a Linux client build that includes that SDL fix.** It is not enough for the patch to exist upstream in SDL; the Steam client on Linux has to actually bundle and use it.
- **Linux-side access to the real Flydigi `hidraw` interface must work without local overrides.** If Steam cannot open the controller's vendor HID interface as the logged-in user, the local udev rule is still needed.
- **The generic `xpad` path must stop winning over the real Flydigi HID path.** If Steam still falls back to the Xbox-facing interface first, the local `xpad` unbind rule is still needed.

Who needs to change what:

- **SDL:** merge and ship the protocol fix.
- **Valve / Steam:** bundle a Steam-for-Linux client SDL with that fix.
- **Linux distro / local OS setup:** make sure the real Flydigi HID interface is accessible and not masked by the generic Xbox path.

## Troubleshooting

**Controller still shows as Generic X-Box pad after install:**

1. Replug the controller — the udev xpad-unbind rule only fires on device add.
2. Confirm the wrapper is active:
   ```sh
   systemctl --user status steam-launcher.service | grep ExecStart
   # Should show vader5-driver/wrapper.sh
   ```
   Confirm the patched SDL is loaded:
   ```sh
   pid=$(pgrep -f 'ubuntu12_32/steam ' | head -1)
   grep libSDL3 /proc/$pid/maps | sort -u
   # Should show vader5-driver/sdl/libSDL3-32.so.0
   ```
3. Confirm xpad is unbound:
   ```sh
   ls /sys/bus/usb/drivers/xpad/
   # Should NOT show the Vader's interface (e.g. 3-1:1.0)
   ```
4. Check Steam's controller log:
   ```sh
   grep -n 'Flydigi\|Vader\|HIDAPI' ~/.local/share/Steam/logs/controller.txt | tail -40
   ```

**Build fails at 32-bit cmake:**

```sh
ls /usr/lib32/pkgconfig/ | grep -E '^x11|xext'
sudo pacman -S --needed lib32-libx11 lib32-libxext   # Arch/SteamOS
# or: sudo apt-get install -y libx11-dev:i386 libxext-dev:i386   # Ubuntu
```

**SDL patch doesn't apply:**

The patch targets SDL `release-3.4.4`. If you point the installer at a different SDL tree and the file layout has changed, apply the patch manually. If `SDL_HIDAPI_Flydigi_UsesUnnumbered32ByteReports` already exists in the source, this specific patch is no longer needed.
