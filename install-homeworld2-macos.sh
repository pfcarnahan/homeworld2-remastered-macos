#!/bin/bash
# =============================================================================
#  Homeworld 2 Remastered on Apple Silicon — guided installer
#
#  Runs Homeworld Remastered Collection (Steam app 244160, Windows build) under
#  Whisky, with OpenGL served by WineMetalGL (GL -> Metal, no Vulkan, no Mesa).
#
#  Why this is necessary: Apple's OpenGL stops at 4.1 core / 2.1 legacy, and the
#  game asks for a 3.3 **compatibility** profile. Wine's built-in OpenGL cannot
#  satisfy that, so the game dies at startup with "OpenGL failed to load".
#  WineMetalGL implements GL 1.0-4.6 in compatibility profile directly on Metal.
#
#  Everything mechanical is automated. The script stops and waits only where a
#  human is genuinely required: Steam login (including 2FA) and clicking
#  Install in Steam's UI.
#
#  Usage:  ./install-homeworld2-macos.sh [options]
#    --bottle NAME        Whisky bottle to use/create   (default: Steam)
#    --resolution WxH     game + virtual desktop size   (default: match display)
#    --no-virtual-desktop disable Whisky's virtual desktop
#    --yes                non-interactive; accept defaults
#    --skip-verify        do not launch the game at the end
#    --dry-run            report what would happen, change nothing
#    --selftest           run internal checks against temp copies, exit
# =============================================================================
set -euo pipefail

APPID=244160
GAME_NAME="Homeworld Remastered Collection"
BOTTLE="Steam"
RESOLUTION=""
VIRTUAL_DESKTOP=1
ASSUME_YES=0
SKIP_VERIFY=0
DRY_RUN=0
SELFTEST=0
FALLBACK_LAUNCHER=0

WMG_VERSION="winemetalgl-3.7.0"
WMG_URL="https://github.com/metalsharp/WineMetalGL/releases/download/${WMG_VERSION}/install-wine-module.sh"
STEAM_SETUP_URLS=(
  "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
  "https://media.steampowered.com/client/installer/SteamSetup.exe"
)

# --- colours (disabled when not a tty) ---------------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; DIM=""; G=""; Y=""; R=""; N=""
fi

STEP=0
step()  { STEP=$((STEP+1)); printf '\n%s[%d]%s %s%s%s\n' "$B" "$STEP" "$N" "$B" "$*" "$N"; }
ok()    { printf '    %sOK%s   %s\n' "$G" "$N" "$*"; }
warn()  { printf '    %sWARN%s %s\n' "$Y" "$N" "$*"; }
die()   { printf '\n%sERROR%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
note()  { printf '    %s%s%s\n' "$DIM" "$*" "$N"; }
run()   { if [ "$DRY_RUN" = 1 ]; then printf '    %s[dry-run]%s %s\n' "$DIM" "$N" "$*"; else "$@"; fi; }

confirm() {  # confirm "question" [default-yes]
  local q="$1" def="${2:-y}" ans
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  printf '    %s%s%s [%s] ' "$B" "$q" "$N" "$([ "$def" = y ] && echo 'Y/n' || echo 'y/N')"
  read -r ans </dev/tty || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

pause_for() { # pause_for "instruction"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  printf '\n    %s%s%s\n    Press Return when done... ' "$B" "$1" "$N"
  read -r _ </dev/tty || true
}

# --- path helpers ------------------------------------------------------------
WHISKY_SUPPORT="$HOME/Library/Application Support/com.franke.Whisky"
WINE_ROOT="$WHISKY_SUPPORT/Libraries/Wine"
WHISKY_BOTTLES="$HOME/Library/Containers/com.franke.Whisky/Bottles"
WHISKY_APP="/Applications/Whisky.app"
WHISKY_CMD="$WHISKY_APP/Contents/Resources/WhiskyCmd"

find_wine() {
  local candidates=(
    "$WINE_ROOT/bin/wine64"
    "$WHISKY_APP/Contents/Resources/Libraries/Wine/bin/wine64"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# Resolve a bottle name to its prefix directory on disk.
bottle_prefix() {
  local name="$1" dir uuid
  # Preferred: ask Whisky itself, then map the UUID onto the real container path.
  if [ -x "$WHISKY_CMD" ]; then
    uuid=$("$WHISKY_CMD" list 2>/dev/null | grep -F "| $name " | sed -n 's#.*Bottles/\([A-Za-z0-9-]*\).*#\1#p' | head -1 || true)
    if [ -n "${uuid:-}" ] && [ -d "$WHISKY_BOTTLES/$uuid" ]; then
      printf '%s' "$WHISKY_BOTTLES/$uuid"; return 0
    fi
  fi
  # Fallback: match Metadata.plist name.
  for dir in "$WHISKY_BOTTLES"/*/; do
    [ -f "$dir/Metadata.plist" ] || continue
    local bn
    bn=$(/usr/libexec/PlistBuddy -c "Print :name" "$dir/Metadata.plist" 2>/dev/null || true)
    [ "${bn:-}" = "$name" ] && { printf '%s' "${dir%/}"; return 0; }
  done
  return 1
}

steam_exe() { printf '%s' "$1/drive_c/Program Files (x86)/Steam/steam.exe"; }

# Locate an installed Steam app's manifest, following extra library folders.
find_appmanifest() {
  local prefix="$1" appid="$2" hit
  hit=$(find "$prefix/drive_c" -maxdepth 6 -name "appmanifest_${appid}.acf" -print -quit 2>/dev/null || true)
  [ -n "$hit" ] && printf '%s' "$hit"
}

game_exe_from_manifest() { # manifest -> path of HomeworldRM.exe
  local manifest="$1" installdir lib
  installdir=$(grep -o '"installdir"[^"]*"[^"]*"' "$manifest" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
  [ -n "$installdir" ] || return 1
  lib=$(dirname "$(dirname "$manifest")")                  # .../Steam
  find "$lib/steamapps/common/$installdir" -maxdepth 4 -name 'HomeworldRM.exe' -print -quit 2>/dev/null || true
}

# --- config writers (also used by --selftest) --------------------------------
ensure_bottle_override() { # ensure_bottle_override <Metadata.plist> <dll> <mode>
  local plist="$1" dll="$2" mode="$3" pb=/usr/libexec/PlistBuddy count i have
  [ -f "$plist" ] || return 1
  count=$("$pb" -c "Print :customDLLOverrides" "$plist" 2>/dev/null | grep -c 'dllName' || true)
  count="${count:-0}"
  for ((i=0; i<count; i++)); do
    local cur
    cur=$("$pb" -c "Print :customDLLOverrides:$i:dllName" "$plist" 2>/dev/null || true)
    [ "$cur" = "$dll" ] && have=$i && break
  done
  if [ -n "${have:-}" ]; then
    "$pb" -c "Set :customDLLOverrides:$have:mode $mode" "$plist" >/dev/null 2>&1 || return 1
    printf 'updated'
  else
    "$pb" -c "Add :customDLLOverrides:$count:dllName string $dll" "$plist" >/dev/null 2>&1 || return 1
    "$pb" -c "Add :customDLLOverrides:$count:mode string $mode" "$plist" >/dev/null 2>&1 || return 1
    printf 'added'
  fi
}

set_display_config() { # set_display_config <Metadata.plist> <virtualDesktop 0|1> <preset> <w> <h>
  local plist="$1" vd="$2" preset="$3" w="$4" h="$5" pb=/usr/libexec/PlistBuddy
  _set_or_add() { # _set_or_add <path> <type> <value>
    "$pb" -c "Set $1 $3" "$plist" >/dev/null 2>&1 \
      || "$pb" -c "Add $1 $2 $3" "$plist" >/dev/null 2>&1 || true
  }
  _set_or_add ":displayConfig:virtualDesktopEnabled" bool "$([ "$vd" = 1 ] && echo true || echo false)"
  _set_or_add ":displayConfig:resolutionPreset" string "$preset"
  if [ -n "$w" ] && [ -n "$h" ]; then
    _set_or_add ":displayConfig:customWidth" integer "$w"
    _set_or_add ":displayConfig:customHeight" integer "$h"
  fi
}

write_launcher_settings() { # write_launcher_settings <hws file> <windowed 0|1>
  local f="$1" windowed="$2"
  [ -f "$f" ] || return 1
  if [ "$windowed" = 0 ]; then
    sed -i '' 's|<bWindowed>true</bWindowed>|<bWindowed>false</bWindowed>|' "$f"
  else
    sed -i '' 's|<bWindowed>false</bWindowed>|<bWindowed>true</bWindowed>|' "$f"
  fi
}

write_player_cfg() { # write_player_cfg <PLAYERCFG.LUA> <w> <h>
  local f="$1" w="$2" h="$3"
  [ -f "$f" ] || return 1
  sed -i '' -e 's/screenFullscreen = 0/screenFullscreen = 1/' \
            -e "s/screenResolutionW = [0-9]*/screenResolutionW = $w/" \
            -e "s/screenResolutionH = [0-9]*/screenResolutionH = $h/" "$f"
}

# --- selftest ----------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
  /usr/bin/plutil -create xml1 "$TMPD/Metadata.plist"
  /usr/libexec/PlistBuddy -c "Add :name string Selftest" "$TMPD/Metadata.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :customDLLOverrides array" "$TMPD/Metadata.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :displayConfig dict" "$TMPD/Metadata.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :displayConfig:virtualDesktopEnabled bool false" "$TMPD/Metadata.plist" >/dev/null

  echo "1. add entry to empty array:      $(ensure_bottle_override "$TMPD/Metadata.plist" opengl32 n,b)"
  echo "   lint:                          $(/usr/bin/plutil -lint "$TMPD/Metadata.plist" >/dev/null 2>&1 && echo pass || echo FAIL)"
  echo "   name present:                  $(/usr/libexec/PlistBuddy -c 'Print :customDLLOverrides:0:dllName' "$TMPD/Metadata.plist")"
  echo "2. re-run is idempotent:          $(ensure_bottle_override "$TMPD/Metadata.plist" opengl32 n,b)  (mode now $(/usr/libexec/PlistBuddy -c 'Print :customDLLOverrides:0:mode' "$TMPD/Metadata.plist"))"
  echo "   count of entries:              $(/usr/libexec/PlistBuddy -c 'Print :customDLLOverrides' "$TMPD/Metadata.plist" | grep -c dllName)"
  echo "3. add a second, unrelated dll:   $(ensure_bottle_override "$TMPD/Metadata.plist" dxvk n,b)"
  echo "   count of entries:              $(/usr/libexec/PlistBuddy -c 'Print :customDLLOverrides' "$TMPD/Metadata.plist" | grep -c dllName)"
  echo "4. display config (custom):       $(set_display_config "$TMPD/Metadata.plist" 1 custom 2560 1440; /usr/libexec/PlistBuddy -c 'Print :displayConfig' "$TMPD/Metadata.plist" | tr -d '\n ')"

  printf '<Root>\n  <bWindowed>true</bWindowed>\n</Root>\n' > "$TMPD/LauncherSettings.hws"
  write_launcher_settings "$TMPD/LauncherSettings.hws" 0
  echo "5. launcher windowed->false:      $(grep -o '<bWindowed>[a-z]*</bWindowed>' "$TMPD/LauncherSettings.hws")"

  printf 'VideoOptions = {\n    screenFullscreen = 0,\n    screenResolutionW = 1512,\n    screenResolutionH = 982,\n}\n' > "$TMPD/PLAYERCFG.LUA"
  write_player_cfg "$TMPD/PLAYERCFG.LUA" 2560 1440
  echo "6. playercfg fullscreen+res:      $(grep -E 'screenFullscreen|screenResolutionW|screenResolutionH' "$TMPD/PLAYERCFG.LUA" | tr -d ' \n')"
  echo "7. plist still valid:             $(/usr/bin/plutil -lint "$TMPD/Metadata.plist" >/dev/null 2>&1 && echo pass || echo FAIL)"
  exit 0
fi

# --- argument parsing --------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --bottle)              BOTTLE="${2:?}"; shift 2 ;;
    --resolution)          RESOLUTION="${2:?}"; shift 2 ;;
    --no-virtual-desktop)  VIRTUAL_DESKTOP=0; shift ;;
    --yes|-y)              ASSUME_YES=1; shift ;;
    --skip-verify)         SKIP_VERIFY=1; shift ;;
    --with-fallback-launcher) FALLBACK_LAUNCHER=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                     die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -n "$RESOLUTION" ] && ! [[ "$RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]]; then
  die "--resolution wants WxH, e.g. 2560x1440"
fi

printf '%sHomeworld 2 Remastered — Apple Silicon installer%s\n' "$B" "$N"
note "Steam app 244160, Windows build, run under Whisky with WineMetalGL."
note "You will be asked to log into Steam once. Nothing else needs a GUI."

# --- 1. preflight ------------------------------------------------------------
step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || die "This is macOS only."
ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] || die "Apple Silicon required (found $ARCH). Intel Macs need a different path."
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$OS_MAJOR" -ge 14 ] || die "macOS 14 (Sonoma) or newer required; this is $(sw_vers -productVersion)."
ok "macOS $(sw_vers -productVersion) on $ARCH"

FREE_GB=$(( $(df -g / | awk 'NR==2 {print $4}') ))
if [ "$FREE_GB" -lt 25 ]; then
  warn "only ${FREE_GB} GB free; the game needs ~8 GB plus a Wine runtime (~1 GB)."
  confirm "Continue anyway?" n || die "Not enough disk space."
else
  ok "${FREE_GB} GB free"
fi

# --- 2. Whisky ---------------------------------------------------------------
step "Whisky"
if [ -d "$WHISKY_APP" ]; then
  ok "Whisky present ($(defaults read "$WHISKY_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?'))"
else
  warn "Whisky is not installed."
  note "Whisky is a Wine wrapper for macOS. Its Homebrew cask was retired in 2026, so the"
  note "installer fetches the app directly from the project's own download page."
  if confirm "Download and install Whisky now?" y; then
    TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
    DMG="$TMPD/Whisky.dmg"
    curl -fL --progress-bar "https://getwhisky.app/latest/Whisky.dmg" -o "$DMG" \
      || die "Download failed. Install Whisky manually from https://getwhisky.app and re-run."
    run hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$TMPD/mnt"
    run cp -R "$TMPD/mnt/Whisky.app" /Applications/
    run hdiutil detach "$TMPD/mnt" -quiet
    run xattr -dr com.apple.quarantine "$WHISKY_APP" 2>/dev/null || true
    [ -d "$WHISKY_APP" ] || die "Whisky did not land in /Applications."
    ok "Whisky installed"
  else
    die "Whisky is required. Install it from https://getwhisky.app, then re-run this script."
  fi
fi

# --- 3. Whisky's Wine runtime ------------------------------------------------
step "Wine runtime"
if WINE=$(find_wine); then
  ok "found $(dirname "$(dirname "$WINE")")"
else
  warn "Whisky has not downloaded its Wine runtime yet."
  note "Launching Whisky once; it fetches its runtime on first run. This can take a few minutes."
  run open -a "$WHISKY_APP"
  for i in $(seq 1 60); do
    sleep 5
    if WINE=$(find_wine); then break; fi
    printf '.'
  done
  echo
  WINE=$(find_wine) || die "Wine runtime still missing. Open Whisky once, let it finish setup, re-run."
  ok "runtime ready"
fi
[ -x "$WHISKY_CMD" ] || die "WhiskyCmd not found inside Whisky.app; Whisky version too old? Need 3.x."

# --- 4. bottle ---------------------------------------------------------------
step "Whisky bottle '$BOTTLE'"
if PREFIX=$(bottle_prefix "$BOTTLE"); then
  ok "using existing bottle at $PREFIX"
else
  note "No bottle named '$BOTTLE'; creating it (Windows 10, default settings)."
  run "$WHISKY_CMD" create "$BOTTLE" || die "Bottle creation failed."
  PREFIX=$(bottle_prefix "$BOTTLE") || die "Bottle '$BOTTLE' was created but cannot be located on disk."
  ok "created $PREFIX"
fi

# --- 5. Steam ----------------------------------------------------------------
step "Steam (Windows client inside the bottle)"
STEAM_EXE=$(steam_exe "$PREFIX")
if [ -f "$STEAM_EXE" ]; then
  ok "already installed"
else
  note "Downloading the Windows Steam installer and running it silently."
  TMPD=${TMPD:-$(mktemp -d)}
  trap 'rm -rf "$TMPD"' EXIT
  SETUP="$TMPD/SteamSetup.exe"
  got=0
  for u in "${STEAM_SETUP_URLS[@]}"; do
    if curl -fL --progress-bar "$u" -o "$SETUP"; then got=1; break; fi
  done
  [ "$got" = 1 ] || die "Could not download SteamSetup.exe."
  note "Installing (a window may flash; it closes on its own)."
  ( export WINEPREFIX="$PREFIX" WINEDEBUG=-all
    "$WINE" "$SETUP" /S ) || die "Steam installer returned an error."
  for i in $(seq 1 60); do
    [ -f "$STEAM_EXE" ] && break
    sleep 2
  done
  [ -f "$STEAM_EXE" ] || die "Steam did not install. Try running SteamSetup.exe manually inside Whisky."
  ok "Steam installed"
fi

# --- 6. WineMetalGL ----------------------------------------------------------
step "WineMetalGL (OpenGL -> Metal)"
FORWARDER="$PREFIX/drive_c/windows/syswow64/opengl32.dll"
CORE="$WINE_ROOT/lib/wine/x86_64-unix/libwinemetalgl.dylib"
[ -f "$CORE" ] || CORE="$(find "$WHISKY_SUPPORT/Libraries/Wine" -name 'libwinemetalgl.dylib' 2>/dev/null | head -1)"
if [ -f "$FORWARDER" ] && [ -n "${CORE:-}" ] && [ -f "$CORE" ]; then
  ok "already installed"
else
  note "Fetching the official installer and installing into this Wine + bottle."
  TMPD=${TMPD:-$(mktemp -d)}
  trap 'rm -rf "$TMPD"' EXIT
  WMG_SH="$TMPD/install-wine-module.sh"
  curl -fL --progress-bar "$WMG_URL" -o "$WMG_SH" || die "Could not download WineMetalGL installer."
  # install-wine-module.sh <wine root> <prefix>
  if ! run sh "$WMG_SH" "$WINE_ROOT" "$PREFIX"; then
    warn "Automatic install failed. Manual route:"
    note "  1. Download the WineMetalGL DMG from github.com/metalsharp/WineMetalGL/releases"
    note "  2. Open it, choose 'Custom Install', point it at:"
    note "     Wine:   $WINE_ROOT"
    note "     Prefix: $PREFIX"
    die "WineMetalGL not installed — OpenGL would still fail."
  fi
  [ -f "$PREFIX/drive_c/windows/syswow64/opengl32.dll" ] || die "WineMetalGL installer ran but no forwarder appeared."
  ok "installed"
fi

# --- 7. override that survives Whisky ---------------------------------------
step "DLL override (Whisky rewrites its own list on every launch)"
METADATA="$PREFIX/Metadata.plist"
if [ -f "$METADATA" ]; then
  cp "$METADATA" "$METADATA.hw2-backup" 2>/dev/null || true
  RES=$(ensure_bottle_override "$METADATA" opengl32 n,b) || RES="failed"
  if /usr/bin/plutil -lint "$METADATA" >/dev/null 2>&1; then
    ok "bottle override ${RES} (opengl32 = n,b) — backup at Metadata.plist.hw2-backup"
  else
    cp "$METADATA.hw2-backup" "$METADATA"
    warn "Metadata edit failed validation and was rolled back."
    note "Add it by hand: Whisky -> bottle -> Settings -> DLL Overrides ->"
    note "  name 'opengl32', mode 'Native then Builtin'."
  fi
else
  warn "No Metadata.plist in this bottle; skipping (the launcher sets the override itself)."
fi

# Registry, so plain launches also work until Whisky's next rewrite.
( export WINEPREFIX="$PREFIX" WINEDEBUG=-all
  "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v opengl32 /d native /f >/dev/null 2>&1 ) \
  && ok "registry override set (opengl32 = native)" || warn "registry override failed (non-fatal)"

# --- 8. display / virtual desktop -------------------------------------------
step "Display"
if [ -n "$RESOLUTION" ]; then
  RES_W="${RESOLUTION%x*}"; RES_H="${RESOLUTION#*x}"; PRESET="custom"
else
  PRESET="matchDisplay"; RES_W=""; RES_H=""
fi
if [ -f "$METADATA" ]; then
  run set_display_config "$METADATA" "$VIRTUAL_DESKTOP" "$PRESET" "$RES_W" "$RES_H"
  /usr/bin/plutil -lint "$METADATA" >/dev/null 2>&1 || { cp "$METADATA.hw2-backup" "$METADATA"; warn "rolled back"; }
  ok "virtual desktop: $([ "$VIRTUAL_DESKTOP" = 1 ] && echo on || echo off), size: ${RESOLUTION:-match display}"
fi
[ "$VIRTUAL_DESKTOP" = 1 ] && note "Virtual desktop is what keeps the mouse clipped to the game. Turn it off if it misbehaves."

# --- 9. Steam login + game install ------------------------------------------
step "Installing the game (this part needs you)"
MANIFEST=$(find_appmanifest "$PREFIX" "$APPID" || true)
if [ -n "$MANIFEST" ]; then
  ok "app $APPID already installed"
else
  note "Steam will open in a Wine window. Log in (2FA included), then install"
  note "'$GAME_NAME' from your library — or let this script start the download for you."
  ( export WINEPREFIX="$PREFIX" WINEDEBUG=-all
    "$WINE" start /unix "$STEAM_EXE" -no-cef-sandbox >/dev/null 2>&1 & ) || true
  sleep 8
  if confirm "Start the $GAME_NAME download automatically?" y; then
    ( export WINEPREFIX="$PREFIX" WINEDEBUG=-all
      "$WINE" start /unix "steam://install/$APPID" >/dev/null 2>&1 & ) || true
    note "If Steam asks which library, pick the default one."
  fi
  note "Waiting for the $APPID manifest (~8 GB download). Ctrl-C is safe; re-run to resume."
  for i in $(seq 1 720); do   # up to 2 hours, polled every 10s
    MANIFEST=$(find_appmanifest "$PREFIX" "$APPID" || true)
    [ -n "$MANIFEST" ] && break
    sleep 10
    [ $((i % 6)) -eq 0 ] && printf '.'
  done
  echo
  [ -n "$MANIFEST" ] || die "Game not installed yet. Log into Steam, install it, then re-run this script — it picks up where it left off."
  ok "installed: $MANIFEST"
fi

GAME_EXE=$(game_exe_from_manifest "$MANIFEST") || die "Could not locate HomeworldRM.exe from $MANIFEST"
ok "$GAME_EXE"
GAME_BIN=$(dirname "$GAME_EXE")

# --- 10. game settings -------------------------------------------------------
step "Game settings (fullscreen, resolution)"
LHS=$(find "$PREFIX/drive_c/users" -path '*Homeworld Remastered/LauncherData/LauncherSettings.hws' -print -quit 2>/dev/null || true)
if [ -n "${LHS:-}" ]; then
  cp "$LHS" "$LHS.hw2-backup" 2>/dev/null || true
  run write_launcher_settings "$LHS" 0
  ok "Aspyr launcher windowed flag cleared"
else
  note "LauncherSettings.hws not created yet (appears after the game's launcher runs once). Skipping."
fi

HW2_ROOT=$(dirname "$(dirname "$GAME_BIN")")   # .../HomeworldRM
PCFG=$(find "$HW2_ROOT" -name 'PLAYERCFG.LUA' -print -quit 2>/dev/null || true)
if [ -n "${PCFG:-}" ]; then
  cp "$PCFG" "$PCFG.hw2-backup" 2>/dev/null || true
  if [ -n "$RES_W" ]; then run write_player_cfg "$PCFG" "$RES_W" "$RES_H"
  else
    CUR_W=$(grep -o 'screenResolutionW = [0-9]*' "$PCFG" | grep -o '[0-9]*$' || echo 1512)
    CUR_H=$(grep -o 'screenResolutionH = [0-9]*' "$PCFG" | grep -o '[0-9]*$' || echo 982)
    run write_player_cfg "$PCFG" "$CUR_W" "$CUR_H"
  fi
  ok "fullscreen enabled${RES_W:+, ${RES_W}x$RES_H}"
else
  note "No PLAYERCFG.LUA yet; set fullscreen in the game's Options on first run."
  RES_W=${RES_W:-1512}; RES_H=${RES_H:-982}
fi

# --- 11. launcher ------------------------------------------------------------
step "Launcher"
# Whisky creates a working one-click shortcut by itself when a Steam game is
# installed: <app>/Contents/MacOS/run.sh is `open steam://run/244160`, and Whisky
# registers itself as the steam:// handler, so the URL is delivered to the BOTTLE's
# Steam (verified: the frontmost process after the click is Whisky's wine binary,
# and no native Steam is launched). So this step only checks it exists.
SHORTCUT=""
for cand in "$HOME/Applications"/*Homeworld*.app; do
  [ -d "$cand" ] && { SHORTCUT="$cand"; break; }
done
if [ -n "$SHORTCUT" ]; then
  ok "Whisky shortcut present: $(basename "$SHORTCUT")"
else
  note "No shortcut yet; asking Whisky to create one."
  SHORTCUT="$HOME/Applications/Homeworld Remastered Collection.app"
  if run "$WHISKY_CMD" shortcut "$BOTTLE" "$GAME_EXE" --name "Homeworld 2 Remastered" --overwrite >/dev/null 2>&1; then
    for cand in "$HOME/Applications"/*Homeworld*.app; do
      [ -d "$cand" ] && { SHORTCUT="$cand"; break; }
    done
    ok "created $(basename "$SHORTCUT")"
  else
    warn "Shortcut creation failed; make one in Whisky's UI (bottle -> game -> Create shortcut)."
    SHORTCUT=""
  fi
fi

# Optional fallback: forces the opengl32 override via the environment and writes a
# plain-text launch log. Only needed for diagnosis or if a future Whisky stops
# exporting the override. Normal use never touches this.
if [ "$FALLBACK_LAUNCHER" = 1 ]; then
  step "Fallback launcher (optional)"
  LAUNCHER="$HOME/Desktop/Homeworld 2 Remastered.command"
  if [ "$DRY_RUN" = 1 ]; then
    ok "[dry-run] would write $LAUNCHER"
  else
cat > "$LAUNCHER" <<LAUNCH_EOF
#!/bin/bash
# Homeworld 2 Remastered — fallback launcher (install-homeworld2-macos.sh)
# Not needed for normal play: use Whisky's shortcut. This exists for diagnosis and
# for the case where a Whisky build stops exporting the opengl32 override, because
# WINEDLLOVERRIDES in the environment outranks the prefix registry.
set -uo pipefail
WINE="$WINE"
PREFIX="$PREFIX"
GAME="$GAME_EXE"
STEAM="$STEAM_EXE"
LOG="\$HOME/Library/Logs/hw2-launch.log"
mkdir -p "\$(dirname "\$LOG")"
export WINEPREFIX="\$PREFIX"
export WINEDLLOVERRIDES="d3d10core=n,b;d3d11=n,b;d3d12=;dxgi=n,b;opengl32=n,b;winemetal=b"
export WINEESYNC=1 WINEMSYNC=1 WINEFSYNC=0
export WINE_SIGPIPE_IGNORE=1 WINE_DISABLE_NTDLL_THREAD_REGS=1
export LC_ALL=en_US.UTF-8 LC_NUMERIC=C LANG=en_US.UTF-8
export WINEDEBUG=fixme-all
{ echo "== \$(date) =="; } >> "\$LOG"
if ! pgrep -f "steam.exe" >/dev/null 2>&1; then
  "\$WINE" start /unix "\$STEAM" -no-cef-sandbox >> "\$LOG" 2>&1 &
  sleep 35
fi
exec "\$WINE" start /unix "\$GAME" \\
  -dlccampaign HW2Campaign.big -campaign Homeworld2Classic -moviepath DataHW2Campaign \\
  >> "\$LOG" 2>&1
LAUNCH_EOF
    chmod +x "$LAUNCHER"
    ok "$LAUNCHER"
  fi
fi

# --- 12. verify --------------------------------------------------------------
# Launch the executable directly rather than through Steam's UI: this tests the
# thing that can actually be wrong (does OpenGL come up as WineMetalGL?), and it
# does not depend on Steam being logged in, updated, or showing any dialog.
if [ "$SKIP_VERIFY" = 1 ] || [ "$DRY_RUN" = 1 ]; then
  step "Skipping launch verification"
else
  step "Verifying (starting the game once, ~40 seconds)"
  GAMELOG="$GAME_BIN/HwRM.log"
  rm -f "$GAMELOG"
  note "A game window will open and be closed again. No Steam dialog is involved."
  (
    export WINEPREFIX="$PREFIX"
    export WINEDLLOVERRIDES="d3d10core=n,b;d3d11=n,b;d3d12=;dxgi=n,b;opengl32=n,b;winemetal=b"
    export WINEESYNC=1 WINEDEBUG=fixme-all
    "$WINE" start /unix "$GAME_EXE" >/dev/null 2>&1
  ) &
  RENDERER=""
  for i in $(seq 1 40); do
    sleep 3
    if [ -f "$GAMELOG" ]; then
      RENDERER=$(tr -d '\000' < "$GAMELOG" 2>/dev/null | grep -i 'GL Renderer' | tail -1 || true)
    fi
    [ -n "${RENDERER:-}" ] && break
  done
  pkill -f 'HomeworldRM.exe' >/dev/null 2>&1 || true

  if printf '%s' "$RENDERER" | grep -qi 'WineMetalGL'; then
    ok "${RENDERER#*: }"
    ok "OpenGL is being served by WineMetalGL — hardware rendering, no Vulkan."
  else
    warn "No WineMetalGL renderer line appeared in the game log."
    if [ -f "$GAMELOG" ]; then
      note "Last lines of $GAMELOG:"
      tr -d '\000' < "$GAMELOG" 2>/dev/null | tail -15 | sed 's/^/      /'
    else
      note "The game never wrote $GAMELOG — it did not get far enough to initialise."
    fi
    note "Most likely: the opengl32 override is missing from the bottle. Re-run this"
    note "script, or check Whisky -> bottle -> Settings -> DLL Overrides for"
    note "opengl32 = Native then Builtin."
    die "Verification failed."
  fi
fi

cat <<SUMMARY

$(printf '%sDone.%s' "$G" "$N")

  Play:        launch "Homeworld 2 Remastered" from ~/Applications, or from Steam
  Game log:    $GAME_BIN/HwRM.log    (renderer string lives here)

  Backups:     Metadata.plist.hw2-backup, *.hw2-backup next to each edited file
  Undo OpenGL: delete $PREFIX/drive_c/windows/syswow64/opengl32.dll

  Known limits (Wine, not this setup):
   - Cmd-Tab out and back can drop the mouse clip; click once inside the game.
   - For an external monitor, set the resolution with --resolution WxH and make
     that display the main one in System Settings -> Displays.
   - If fullscreen misbehaves, add -windowed to the launcher's argument list.

SUMMARY
