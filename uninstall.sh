#!/usr/bin/env bash
# RMN-Player Linux Uninstaller
# Completely removes RMN-Player, desktop shortcuts, and associations

set -e

APP_NAME="RMN-Player"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP_NAME"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
PIXMAPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pixmaps"
MIME_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"

echo "========================================"
echo "    RMN-Player Linux Uninstaller"
echo "========================================"
echo ""

# Remove binary launcher
if [ -f "$BIN_DIR/rmn-player" ]; then
    rm -f "$BIN_DIR/rmn-player"
    echo "[OK] Removed launcher: $BIN_DIR/rmn-player"
fi

# Remove desktop entries
if [ -f "$APPS_DIR/rmn-player.desktop" ]; then
    rm -f "$APPS_DIR/rmn-player.desktop"
    echo "[OK] Removed application entry: $APPS_DIR/rmn-player.desktop"
fi

DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
if [ -f "$DESKTOP_DIR/rmn-player.desktop" ]; then
    rm -f "$DESKTOP_DIR/rmn-player.desktop"
    echo "[OK] Removed Desktop shortcut: $DESKTOP_DIR/rmn-player.desktop"
fi

# Remove icons
rm -f "$ICONS_DIR/256x256/apps/rmn-player.png"
rm -f "$PIXMAPS_DIR/rmn-player.png"
echo "[OK] Removed icons"

# Remove application and config files
if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    echo "[OK] Removed config directory: $CONFIG_DIR"
fi

if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "[OK] Removed install directory: $INSTALL_DIR"
fi

# Clean up mimeapps.list
if [ -f "$MIME_FILE" ]; then
    sed -i '/rmn-player\.desktop/d' "$MIME_FILE" 2>/dev/null || true
    echo "[OK] Cleaned file associations in $MIME_FILE"
fi

# Update system caches
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$ICONS_DIR" 2>/dev/null || true
fi

echo ""
echo "========================================"
echo "    Uninstall Complete!"
echo "========================================"
