#!/usr/bin/env bash
# ==============================================================================
# RMN-Player Linux Installer
# Native Linux integration, zero dependencies, full desktop & format associations
# ==============================================================================

set -e

APP_NAME="RMN-Player"
REPO="RMNO21/RMN_Player"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP_NAME"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
PIXMAPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pixmaps"
MIME_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"
FONTS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/RMN-Player"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

write_status() {
    local msg="$1"
    local type="${2:-Info}"
    case "$type" in
        "Success") echo -e "${GREEN}[OK]${NC} $msg" ;;
        "Warning") echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        "Error")   echo -e "${RED}[ERROR]${NC} $msg" ;;
        "Config")  echo -e "${MAGENTA}[CONFIG]${NC} $msg" ;;
        *)         echo -e "${CYAN}[INFO]${NC} $msg" ;;
    esac
}

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}    RMN-Player Linux Installer         ${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Determine source directory (local repo or download)
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
CURRENT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

CLEANUP_TEMP=false
TEMP_DIR=""

if [ -d "$CURRENT_DIR/config" ] && [ -f "$CURRENT_DIR/config/mpv.conf" ]; then
    PACKAGE_DIR="$CURRENT_DIR"
else
    write_status "Running via remote pipe. Fetching package from GitHub..." "Info"
    TEMP_DIR=$(mktemp -d -t rmn_install_XXXXXX)
    CLEANUP_TEMP=true
    
    ZIP_URL="https://github.com/$REPO/archive/refs/heads/main.zip"
    if ! curl -fsSL -A "RMN-Player-Installer" "$ZIP_URL" -o "$TEMP_DIR/rmn.zip"; then
        write_status "Failed to download RMN-Player from GitHub" "Error"
        exit 1
    fi
    unzip -q -o "$TEMP_DIR/rmn.zip" -d "$TEMP_DIR"
    EXTRACTED_ROOT=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
    PACKAGE_DIR="$EXTRACTED_ROOT"
fi

cleanup() {
    if [ "$CLEANUP_TEMP" = true ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# ── 1. Check or install MPV player engine ─────────────────────────────────────
write_status "Checking media player engine..." "Info"
MPV_SYSTEM_BIN=""
if command -v mpv >/dev/null 2>&1; then
    MPV_SYSTEM_BIN="$(command -v mpv)"
    write_status "System mpv found: $MPV_SYSTEM_BIN" "Success"
else
    write_status "System mpv not found." "Warning"
    
    # Try package manager if sudo is available and non-interactive
    INSTALLED_VIA_PKG=false
    if sudo -n true 2>/dev/null; then
        if command -v apt-get >/dev/null 2>&1; then
            write_status "Installing mpv via apt..." "Info"
            sudo apt-get update -qq && sudo apt-get install -y -qq mpv >/dev/null 2>&1 && INSTALLED_VIA_PKG=true
        elif command -v pacman >/dev/null 2>&1; then
            write_status "Installing mpv via pacman..." "Info"
            sudo pacman -Sy --noconfirm mpv >/dev/null 2>&1 && INSTALLED_VIA_PKG=true
        elif command -v dnf >/dev/null 2>&1; then
            write_status "Installing mpv via dnf..." "Info"
            sudo dnf install -y -q mpv >/dev/null 2>&1 && INSTALLED_VIA_PKG=true
        elif command -v zypper >/dev/null 2>&1; then
            write_status "Installing mpv via zypper..." "Info"
            sudo zypper --non-interactive in mpv >/dev/null 2>&1 && INSTALLED_VIA_PKG=true
        fi
    fi

    if [ "$INSTALLED_VIA_PKG" = true ] && command -v mpv >/dev/null 2>&1; then
        MPV_SYSTEM_BIN="$(command -v mpv)"
        write_status "mpv installed via package manager" "Success"
    else
        # Standalone portable engine fallback (Zero Dependencies / Offline)
        write_status "Setting up standalone portable player engine..." "Info"
        mkdir -p "$INSTALL_DIR/player"
        STANDALONE_MPV="$INSTALL_DIR/player/bin/mpv"
        
        if [ ! -x "$STANDALONE_MPV" ] && [ ! -x "$INSTALL_DIR/player/mpv" ]; then
            write_status "Downloading portable MPV package..." "Info"
            TMP_APPIMAGE="/tmp/mpv_pkgforge_$$.AppImage"
            APPIMAGE_URL="https://github.com/pkgforge-dev/mpv-AppImage/releases/download/v0.41.0%402026-10-24_1792872329/mpv-v0.41.0-anylinux-x86_64.AppImage"
            if curl -fsSL -A "RMN-Player" "$APPIMAGE_URL" -o "$TMP_APPIMAGE"; then
                chmod +x "$TMP_APPIMAGE"
                TMP_EXTRACT="/tmp/mpv_ext_$$"
                mkdir -p "$TMP_EXTRACT"
                (cd "$TMP_EXTRACT" && "$TMP_APPIMAGE" --appimage-extract >/dev/null 2>&1)
                cp -rf "$TMP_EXTRACT/squashfs-root/"* "$INSTALL_DIR/player/"
                rm -f "$INSTALL_DIR/player/bin/05-get-yt-dlp.hook"
                rm -rf "$TMP_EXTRACT" "$TMP_APPIMAGE"
                write_status "Standalone player engine ready" "Success"
            else
                write_status "Could not download standalone player. Please install mpv using your package manager." "Error"
                exit 1
            fi
        fi
    fi
fi

# ── 2. Install Configuration Files ───────────────────────────────────────────
write_status "Installing configuration files..." "Config"

mkdir -p "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR/scripts"
mkdir -p "$CONFIG_DIR/scripts/uosc"
mkdir -p "$CONFIG_DIR/script-opts"
mkdir -p "$CONFIG_DIR/fonts"
mkdir -p "$CONFIG_DIR/shaders"
mkdir -p "$CONFIG_DIR/watch_later"
mkdir -p "$CONFIG_DIR/temp_stream_cache"

PACKAGE_CONFIG="$PACKAGE_DIR/config"
if [ -d "$PACKAGE_CONFIG" ]; then
    # Core config files
    for f in mpv.conf input.conf episode-tracker.json version.json; do
        if [ -f "$PACKAGE_CONFIG/$f" ]; then
            cp -f "$PACKAGE_CONFIG/$f" "$CONFIG_DIR/"
            write_status "Copied $f" "Info"
        fi
    done

    # Script options
    if [ -d "$PACKAGE_CONFIG/script-opts" ]; then
        cp -rf "$PACKAGE_CONFIG/script-opts"/* "$CONFIG_DIR/script-opts/"
        write_status "Copied script-opts" "Info"
    fi

    # Fonts
    if [ -d "$PACKAGE_CONFIG/fonts" ]; then
        cp -rf "$PACKAGE_CONFIG/fonts"/* "$CONFIG_DIR/fonts/"
        # Also copy to local fonts directory for system & libass font caching
        mkdir -p "$FONTS_DIR"
        cp -rf "$PACKAGE_CONFIG/fonts"/* "$FONTS_DIR/"
        if command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$FONTS_DIR" >/dev/null 2>&1 || true
        fi
        write_status "Installed fonts" "Info"
    fi

    # Shaders
    if [ -d "$PACKAGE_CONFIG/shaders" ]; then
        cp -rf "$PACKAGE_CONFIG/shaders"/* "$CONFIG_DIR/shaders/"
        write_status "Copied shaders" "Info"
    fi

    # Scripts
    if [ -d "$PACKAGE_CONFIG/scripts" ]; then
        cp -rf "$PACKAGE_CONFIG/scripts"/* "$CONFIG_DIR/scripts/"
        if [ -f "$CONFIG_DIR/scripts/uosc/bin/ziggy-linux" ]; then
            chmod +x "$CONFIG_DIR/scripts/uosc/bin/ziggy-linux" 2>/dev/null || true
        fi
        write_status "Copied scripts" "Info"
    fi

    # Updater script
    if [ -f "$PACKAGE_DIR/update-rmn.sh" ]; then
        cp -f "$PACKAGE_DIR/update-rmn.sh" "$CONFIG_DIR/update-rmn.sh"
        chmod +x "$CONFIG_DIR/update-rmn.sh"
        write_status "Copied update-rmn.sh" "Info"
    fi

    write_status "Configuration files installed to: $CONFIG_DIR" "Success"
else
    write_status "Config directory not found at $PACKAGE_CONFIG" "Error"
    exit 1
fi

# ── 3. Configure thumbfast ───────────────────────────────────────────────────
write_status "Configuring thumbfast preview..." "Config"
THUMBFAST_CONF="$CONFIG_DIR/script-opts/thumbfast.conf"
cat << EOF > "$THUMBFAST_CONF"
# thumbfast.conf - Thumbnail preview configuration
spawn_first=yes
direct_io=no
max_height=200
max_width=200
hwdec=no
network=yes
audio=yes
quit_after_inactivity=0
tone_mapping=auto
mpv_path=$BIN_DIR/rmn-player
EOF
write_status "thumbfast configured" "Success"

# ── 4. Create Launcher Script (rmn-player) ────────────────────────────────────
write_status "Creating launcher script..." "Info"
mkdir -p "$BIN_DIR"
cat << 'EOF' > "$BIN_DIR/rmn-player"
#!/usr/bin/env bash
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/RMN-Player"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/RMN-Player"

# Locate mpv engine
MPV_EXEC=""
if [ -x "$INSTALL_DIR/player/bin/mpv" ]; then
    MPV_EXEC="$INSTALL_DIR/player/bin/mpv"
elif [ -x "$INSTALL_DIR/player/mpv" ]; then
    MPV_EXEC="$INSTALL_DIR/player/mpv"
elif command -v mpv >/dev/null 2>&1; then
    MPV_EXEC="$(command -v mpv)"
fi

if [ -z "$MPV_EXEC" ]; then
    echo "Error: mpv binary not found. Please install mpv or reinstall RMN-Player." >&2
    exit 1
fi

export MPV_HOME="$CONFIG_DIR"
export LC_NUMERIC=C

if [ $# -eq 0 ]; then
    exec "$MPV_EXEC" --config-dir="$CONFIG_DIR" --idle=yes
else
    exec "$MPV_EXEC" --config-dir="$CONFIG_DIR" "$@"
fi
EOF
chmod +x "$BIN_DIR/rmn-player"
write_status "Launcher created: $BIN_DIR/rmn-player" "Success"

# Ensure BIN_DIR is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    write_status "Adding $BIN_DIR to PATH..." "Info"
    for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
        if [ -f "$rc" ] && ! grep -q "$BIN_DIR" "$rc"; then
            echo -e "\nexport PATH=\"$BIN_DIR:\$PATH\"" >> "$rc"
        fi
    done
fi

# ── 5. Install Desktop Shortcut & Icons ──────────────────────────────────────
write_status "Installing desktop entry and icons..." "Info"
mkdir -p "$APPS_DIR"
mkdir -p "$ICONS_DIR"
mkdir -p "$PIXMAPS_DIR"

# Install Icon
if [ -f "$PACKAGE_DIR/config/rmn-icon.png" ]; then
    cp -f "$PACKAGE_DIR/config/rmn-icon.png" "$ICONS_DIR/rmn-player.png"
    cp -f "$PACKAGE_DIR/config/rmn-icon.png" "$PIXMAPS_DIR/rmn-player.png"
fi

# Install Desktop Entry
cat << EOF > "$APPS_DIR/rmn-player.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=RMN-Player
GenericName=Media Player
Comment=High-performance custom media player with OLED-tuned rendering
Exec=$BIN_DIR/rmn-player %U
Icon=rmn-player
Terminal=false
StartupNotify=true
Categories=AudioVideo;Player;Video;Audio;
MimeType=video/x-matroska;video/mp4;video/x-msvideo;video/quicktime;video/x-ms-wmv;video/x-flv;video/webm;video/x-m4v;video/mpeg;video/mp2t;video/x-ogm+ogg;video/3gpp;video/3gpp2;video/divx;video/vnd.rn-realvideo;audio/mpeg;audio/x-flac;audio/x-wav;audio/aac;audio/ogg;audio/opus;audio/x-ms-wma;audio/mp4;audio/m4a;application/ogg;application/x-ogg;application/x-matroska;application/vnd.apple.mpegurl;audio/x-mpegurl;
Keywords=player;media;video;audio;oled;mpv;rmn;
EOF
chmod +x "$APPS_DIR/rmn-player.desktop"

# Desktop folder shortcut
DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
if [ -d "$DESKTOP_DIR" ]; then
    cp -f "$APPS_DIR/rmn-player.desktop" "$DESKTOP_DIR/rmn-player.desktop"
    chmod +x "$DESKTOP_DIR/rmn-player.desktop" 2>/dev/null || true
    write_status "Desktop shortcut created at $DESKTOP_DIR" "Success"
fi

# Update desktop and icon databases
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true
fi

# ── 6. File Associations (Set as default for MKV and all media formats) ──────
write_status "Configuring file associations (Setting RMN-Player as default)..." "Info"

MEDIA_MIMES=(
    "video/x-matroska"
    "application/x-matroska"
    "video/mp4"
    "video/x-msvideo"
    "video/quicktime"
    "video/x-ms-wmv"
    "video/x-flv"
    "video/webm"
    "video/x-m4v"
    "video/mpeg"
    "video/mp2t"
    "video/x-ogm+ogg"
    "video/3gpp"
    "video/3gpp2"
    "video/divx"
    "video/vnd.rn-realvideo"
    "audio/mpeg"
    "audio/mp3"
    "audio/x-flac"
    "audio/flac"
    "audio/x-wav"
    "audio/wav"
    "audio/aac"
    "audio/ogg"
    "audio/opus"
    "audio/x-ms-wma"
    "audio/mp4"
    "audio/m4a"
    "application/ogg"
    "application/x-ogg"
)

# 1. Register with xdg-mime
if command -v xdg-mime >/dev/null 2>&1; then
    for mime in "${MEDIA_MIMES[@]}"; do
        xdg-mime default rmn-player.desktop "$mime" 2>/dev/null || true
    done
    write_status "Registered default associations via xdg-mime" "Success"
fi

# 2. Update mimeapps.list directly to ensure full DE persistence
mkdir -p "$(dirname "$MIME_FILE")"
[ ! -f "$MIME_FILE" ] && touch "$MIME_FILE"

# Python / awk helper to update INI-style mimeapps.list cleanly
python3 - << PYEOF
import os

mime_file = os.path.expanduser("${MIME_FILE}")
desktop = "rmn-player.desktop"
mimes = """${MEDIA_MIMES[*]}""".split()

sections = {"Default Applications": {}, "Added Associations": {}}
current_section = None
lines = []

if os.path.exists(mime_file):
    with open(mime_file, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                current_section = stripped[1:-1]
                if current_section not in sections:
                    sections[current_section] = {}
            elif "=" in stripped and current_section:
                k, v = stripped.split("=", 1)
                sections[current_section][k.strip()] = v.strip()

for m in mimes:
    sections["Default Applications"][m] = desktop
    existing = sections["Added Associations"].get(m, "")
    items = [x for x in existing.split(";") if x and x != desktop]
    items.insert(0, desktop)
    sections["Added Associations"][m] = ";".join(items) + ";"

with open(mime_file, "w", encoding="utf-8") as f:
    for sec, entries in sections.items():
        f.write(f"[{sec}]\n")
        for k, v in sorted(entries.items()):
            f.write(f"{k}={v}\n")
        f.write("\n")
PYEOF

write_status "MKV and all media formats set to open with RMN-Player by default" "Success"

# ── 7. Install Uninstaller ───────────────────────────────────────────────────
if [ -f "$PACKAGE_DIR/uninstall.sh" ]; then
    cp -f "$PACKAGE_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
    chmod +x "$INSTALL_DIR/uninstall.sh"
    write_status "Uninstaller installed to $INSTALL_DIR/uninstall.sh" "Success"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Installation Complete!              ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
write_status "RMN-Player installed to: $INSTALL_DIR" "Success"
write_status "Config files at: $CONFIG_DIR" "Success"
write_status "Binary launcher: $BIN_DIR/rmn-player" "Success"
echo ""
echo -e "${YELLOW}Configured features:${NC}"
echo "  - OLED True Black & deband pipeline"
echo "  - Dynamic ambilight & blur fill"
echo "  - Smart series episode tracking & autoloading"
echo "  - Dual English & Persian keyboard layout support"
echo "  - Native file picker dialog"
echo "  - High-res hover thumbnail previews (thumbfast)"
echo "  - Default player for .mkv, .mp4, and all media formats"
echo "  - Desktop shortcut and application menu launcher"
echo "  - Built-in GitHub updater (Press Shift+U in player or run update-rmn.sh)"
echo ""
echo -e "${CYAN}Run RMN-Player from terminal:${NC} rmn-player <file.mkv>"
echo ""
