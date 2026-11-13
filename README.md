# Homeworld 2 Remastered on Apple Silicon

A guided installer that runs **Homeworld Remastered Collection** (Steam app `244160`) on an
Apple Silicon Mac, with hardware-accelerated OpenGL.

## Why this is needed

The Mac build of Homeworld Remastered is 32-bit only (Intel `i386`). macOS has not run 32-bit
binaries since Catalina, so the native version is dead on any current Mac.

The Windows build runs under Wine — but it fails immediately with **"OpenGL failed to load"**.
The game asks for an **OpenGL 3.3 compatibility profile**, and Apple's OpenGL driver stops at
4.1 *core* and 2.1 *legacy*. There is no compatibility profile. Wine cannot provide one because
it forwards GL straight to the system driver.

The fix is [WineMetalGL](https://github.com/metalsharp/WineMetalGL): an implementation of
OpenGL 1.0–4.6 (compatibility profile, plus GLES 2–3.2) that compiles GLSL to Metal Shading
Language and runs it directly on the GPU. **No Vulkan, no MoltenVK, no Mesa, no software
rendering.** The game gets the context it asks for, at full GPU speed.

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 14 Sonoma or newer
- ~25 GB free disk (game ~8 GB, Wine runtime ~1 GB, rest headroom)
- A Steam account that owns Homeworld Remastered Collection
- Internet access

## Usage

```bash
chmod +x install-homeworld2-macos.sh
./install-homeworld2-macos.sh
```

Useful options:

| Option | Meaning |
|---|---|
| `--resolution 2560x1440` | Set the game + Wine desktop to a fixed size (use your monitor's native resolution) |
| `--bottle NAME` | Use or create a specific Whisky bottle (default `Steam`) |
| `--no-virtual-desktop` | Turn off Whisky's virtual desktop (on by default — it keeps the mouse clipped to the game) |
| `--yes` | Non-interactive, accept all defaults |
| `--skip-verify` | Skip the final launch check |
| `--dry-run` | Report what would be done, change nothing |
| `--with-fallback-launcher` | Also write a desktop `.command` that forces the GL override itself and logs launches. Not needed for normal play |

## What it does automatically

1. Checks macOS version, architecture and free space
2. Installs Whisky if missing — resolved from the maintained fork's latest GitHub release
   (`frankea/Whisky`), because `getwhisky.app` no longer serves a download and the Homebrew cask
   was disabled in 2026
3. Waits for Whisky to fetch its Wine runtime
4. Creates or reuses the Whisky bottle
5. Installs the Windows Steam client into that bottle, silently
6. Installs **WineMetalGL** into both the Wine build and the bottle
7. Writes the `opengl32 = native` DLL override into the bottle's own metadata — **this is the
   step people miss**: Whisky rewrites its override list on every launch, which silently
   disables WineMetalGL and brings back "OpenGL failed to load"
8. Sets up the virtual desktop and resolution
9. Clears the Aspyr launcher's `bWindowed` flag and enables fullscreen in the game profile
10. Confirms Whisky's own one-click shortcut is in place (Whisky creates it when the game
    is installed, and it works because Whisky is the handler for `steam://` URLs)
11. Starts the game once and confirms the renderer came up as WineMetalGL

## What needs you

Only two things, both unavoidable:

1. **Steam login** — including 2FA. The script opens Steam and waits.
2. **Installing the game** — the script can start the download for you (`steam://install/244160`);
   if Steam asks which library, pick the default one.

Expect an ~8 GB download; the script waits for it, and re-running resumes safely.

## How to play

Double-click the **Homeworld Remastered Collection** shortcut Whisky put in `~/Applications`,
or launch it from Steam. Both drive the bottle's own Steam, so the game gets its Steam
context and the WineMetalGL OpenGL path.

## Verify it worked

The game writes its renderer into `HwRM.log`. Two lines matter:

```
GL Info: 4.6 - 4.6.0 WineMetalGL Compatibility Profile
GL Renderer: <your GPU> (WineMetalGL)
```

The installer checks for exactly this. If you see `OpenGL failed to load` instead, the
`opengl32` override is missing — see Troubleshooting.

## Troubleshooting

**Clicking the shortcut shows Steam's install screen.**
That is the macOS Steam client answering the URL, not the bottle's. It happens if Whisky is
not registered as the `steam://` handler (for example, native Steam was installed or updated
afterwards). Launch from Steam inside the bottle instead, or run
`install-homeworld2-macos.sh --with-fallback-launcher` and use that.

**"OpenGL failed to load" came back.**
Whisky rewrote the DLL overrides. Open Whisky → the bottle → Settings → DLL Overrides and
confirm `opengl32` is set to *Native then Builtin*. Alternatively launch the game with the
Desktop `.command`, which sets the override in the environment where Whisky cannot overwrite it.
Re-running the installer also repairs this.

**Mouse stops rotating the camera after Cmd-Tab.**
A Wine limitation, not this setup: regaining window focus does not re-assert the cursor clip.
Click once inside the game window. Turning off *Desktop & Dock → "Displays have separate
Spaces"* (then logging out and in) prevents the Space switch that causes it.

**It plays on the internal screen, I want my external monitor.**
Re-run with `--resolution <your monitor's WxH>`, then drag the Wine window onto the external
display — or make that display the main one in System Settings → Displays, which is also where
fullscreen mouse capture is most reliable.

**It comes up windowed.**
Something set `bWindowed` back to true in `LauncherData/LauncherSettings.hws`, or the launcher's
argument list contains `-windowed`. Re-run the installer (it resets the flag).

**Performance feels low.**
Make sure the game is not in a virtual desktop smaller than your display, and that WineMetalGL
is actually loading (check `HwRM.log`). If the log shows `Mesa` or `zink` instead, leftover
`opengl32.dll` files are sitting next to `HomeworldRM.exe`; they shadow the WineMetalGL
forwarder. Delete them.

## Undo

- OpenGL back to Wine's built-in: delete
  `<bottle>/drive_c/windows/syswow64/opengl32.dll` and `system32/opengl32.dll`, and remove the
  `opengl32` entry from the bottle's DLL Overrides.
- Settings: every file the script edited has a `.hw2-backup` copy next to it, and the bottle's
  metadata is saved as `Metadata.plist.hw2-backup`.
- Nuke it all: delete the bottle in Whisky and reinstall. Nothing outside the bottle is touched
  except the Desktop launcher.

## Files

| Path | Purpose |
|---|---|
| `~/Desktop/Homeworld 2 Remastered.command` | the launcher |
| `~/Library/Logs/hw2-launch.log` | Wine output from launches |
| `<game>/HomeworldRM/bin/Release/HwRM.log` | the game's own log (renderer string lives here) |

## Using this bottle for other Steam games

The OpenGL work is **prefix-wide**, so it applies to every game in that bottle. Any OpenGL title
— including ones that failed with the same compatibility-profile error — now works. DirectX
games are unaffected: they still go through Whisky's DXVK path.

Per-game exceptions are normal Wine: `winecfg` → Applications → add the game's `.exe` →
set `opengl32` to *Builtin*. See the notes at the end of the install for what this does and does
not solve (anti-cheat, notably, is a hard no under Wine).
