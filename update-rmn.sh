#!/usr/bin/env bash
# RMN-Player Linux Auto-Updater
# Non-blocking updater for scripts, shaders, and configs

set -e

REPO="${RMN_REPO:-RMNO21/RMN_Player}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/RMN-Player"
LOCAL_VERSION_FILE="$CONFIG_DIR/version.json"
REMOTE_URL="https://raw.githubusercontent.com/$REPO/main/version.json"
ZIP_URL="https://github.com/$REPO/archive/refs/heads/main.zip"

# Read local version
LOCAL_VERSION="1.0.0"
if [ -f "$LOCAL_VERSION_FILE" ]; then
    V_EXTRACT=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$LOCAL_VERSION_FILE" | head -n1 | cut -d'"' -f4)
    if [ -n "$V_EXTRACT" ]; then
        LOCAL_VERSION="$V_EXTRACT"
    fi
fi

# Fetch remote version
REMOTE_JSON=$(curl -fsSL --connect-timeout 7 -A "RMN-Player" "$REMOTE_URL" 2>/dev/null || true)
if [ -z "$REMOTE_JSON" ]; then
    echo "ERROR: Connection failed"
    exit 1
fi

REMOTE_VERSION=$(echo "$REMOTE_JSON" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | cut -d'"' -f4)
if [ -z "$REMOTE_VERSION" ]; then
    echo "ERROR: Remote version not found"
    exit 1
fi

# Compare versions
version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

if ! version_gt "$REMOTE_VERSION" "$LOCAL_VERSION"; then
    echo "UP_TO_DATE:$LOCAL_VERSION"
    exit 0
fi

# Download and apply update
TEMP_DIR=$(mktemp -d -t rmn_update_XXXXXX)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

TEMP_ZIP="$TEMP_DIR/rmn_update.zip"
if ! curl -fsSL -A "RMN-Player" "$ZIP_URL" -o "$TEMP_ZIP" 2>/dev/null; then
    echo "ERROR: Download failed"
    exit 1
fi

if ! unzip -q -o "$TEMP_ZIP" -d "$TEMP_DIR"; then
    echo "ERROR: Extraction failed"
    exit 1
fi

EXTRACTED_ROOT=$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
SRC_CONFIG="$EXTRACTED_ROOT/config"

if [ -d "$SRC_CONFIG" ]; then
    mkdir -p "$CONFIG_DIR"
    [ -d "$SRC_CONFIG/scripts" ] && cp -rf "$SRC_CONFIG/scripts" "$CONFIG_DIR/"
    [ -d "$SRC_CONFIG/shaders" ] && cp -rf "$SRC_CONFIG/shaders" "$CONFIG_DIR/"
    [ -d "$SRC_CONFIG/fonts" ] && cp -rf "$SRC_CONFIG/fonts" "$CONFIG_DIR/"
    [ -d "$SRC_CONFIG/script-opts" ] && cp -rf "$SRC_CONFIG/script-opts" "$CONFIG_DIR/"
    [ -f "$SRC_CONFIG/input.conf" ] && cp -f "$SRC_CONFIG/input.conf" "$CONFIG_DIR/"
    [ -f "$SRC_CONFIG/version.json" ] && cp -f "$SRC_CONFIG/version.json" "$CONFIG_DIR/"
    [ -f "$EXTRACTED_ROOT/update-rmn.sh" ] && cp -f "$EXTRACTED_ROOT/update-rmn.sh" "$CONFIG_DIR/"
    [ -f "$CONFIG_DIR/scripts/uosc/bin/ziggy-linux" ] && chmod +x "$CONFIG_DIR/scripts/uosc/bin/ziggy-linux" 2>/dev/null || true
fi

echo "UPDATED:$REMOTE_VERSION"
