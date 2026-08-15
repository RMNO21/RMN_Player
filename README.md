<div align="center">

# RMN-Player

A high-performance custom media player for Windows with OLED-tuned rendering, intelligent series tracking, dynamic ambient background lighting, and modern UI.

**100% Offline • Zero Dependencies • Native Windows Integration**

</div>

---

## Key Features

| Feature | Description |
| :--- | :--- |
| **Organic 2D Diffused Ambilight & Blur** | Real-time color-adaptive ambient halo / blurred extension for letterbox and pillarbox bars. 2D spatial diffusion on pure black canvas with zero crop and zero overhead when off. |
| **Smart TV Show Autoloading** | Intelligently identifies same-show episodes across naming styles (`Georgie and Mandy`, `True Detective`) and sorts chronologically while isolating single movies. |
| **Clean Title Sanitizer** | Displays clean video titles without website ads or release tags (e.g. `ValaMovie.Com`). |
| **Unified 3-State Looper** | Single smart button and key shortcut cycling: `Off` → `Loop Playlist (All)` → `Loop Current Episode (One)`. |
| **Dual EN / FA Keyboard Support** | All keyboard shortcuts work seamlessly whether Windows keyboard is set to English or Persian. |
| **Native File Dialog** | Opens native Windows Explorer file picker for selecting media files asynchronously. |
| **OLED True Black & Debanding** | Native 10-bit dithered pipeline with libplacebo debanding for clean gradients and true blacks. |
| **Fast Timeline Previews** | High-speed hover thumbnails via `thumbfast`. |
| **Modern Minimal UI** | Elegant floating controls powered by `uosc`. |

---

## Quick Start

### Installation

1. Download or clone this repository
2. Run `Install-RMN.bat`
3. Done!

```powershell
# Or run via PowerShell:
.\rmn-installer.ps1
```

---

## Keyboard & Mouse Shortcuts

All letter shortcuts are mapped for both **English (EN)** and **Persian (FA)** keyboard layouts:

| Key (EN / FA) | Action |
| :--- | :--- |
| <kbd>Right Click</kbd> | Open context menu anywhere |
| <kbd>Double Click</kbd> / <kbd>Enter</kbd> | Toggle Fullscreen |
| <kbd>Space</kbd> | Play / Pause |
| <kbd>→</kbd> / <kbd>←</kbd> | **Instant Non-Blocking Seek $\pm 3$ seconds** (0ms latency, zero freezing) |
| <kbd>Shift</kbd> + <kbd>→</kbd> / <kbd>←</kbd> | Seek $\pm 30$ seconds |
| <kbd>Ctrl</kbd> + <kbd>→</kbd> / <kbd>←</kbd> | Save position & go to Next / Previous episode |
| <kbd>Mouse Wheel</kbd> / <kbd>↑</kbd> / <kbd>↓</kbd> | Volume $\pm 5\%$ |
| <kbd>b</kbd> / <kbd>ذ</kbd> | **Cycle Background Mode** in Fullscreen (`Normal` → `Blur` → `Ambient Glow`) |
| <kbd>l</kbd> / <kbd>م</kbd> | **Cycle Loop Mode** (`Off` → `Playlist (All)` → `Current Episode (One)`) |
| <kbd>d</kbd> / <kbd>ی</kbd> | Toggle OLED Deband filter (`cycle deband`) |
| <kbd>m</kbd> / <kbd>ئ</kbd> | Mute / Unmute audio |
| <kbd>c</kbd> / <kbd>ز</kbd> | Subtitles menu |
| <kbd>v</kbd> / <kbd>ر</kbd> | Toggle subtitle visibility |
| <kbd>a</kbd> / <kbd>ش</kbd> | Audio tracks menu |
| <kbd>o</kbd> / <kbd>خ</kbd> | Open Windows Explorer file dialog |
| <kbd>u</kbd> / <kbd>ع</kbd> | Open URL popup to stream links |
| <kbd>s</kbd> / <kbd>س</kbd> | Screenshot |
| <kbd>Tab</kbd> | Toggle UI visibility |

---

## Configuration

Configuration files are installed at `%APPDATA%\RMN-Player\`:

```
%APPDATA%\RMN-Player\
├── mpv.conf               # Video & audio rendering pipeline
├── input.conf             # Bilingual keybindings & mouse actions
├── episode-tracker.json   # Local episode tracking database
├── script-opts/
│   ├── uosc.conf          # Modern UI layout & tokens
│   ├── thumbfast.conf     # Thumbnail preview settings
│   └── autoload.conf      # Smart playlist settings
├── scripts/
│   ├── ambient-fill.lua   # Dynamic ambient lighting & blur engine
│   ├── autoload.lua       # Intelligent TV show detection & sorting
│   ├── episode-tracker.lua# Watched tracking & resume
│   ├── loop-cycle.lua     # Unified 3-state loop controller
│   ├── open-url.lua       # Online streaming input popup
│   ├── save-position.lua  # Resume playback manager
│   ├── thumbfast.lua      # Thumbnail engine
│   └── uosc/              # UI framework
└── fonts/                 # High-legibility UI typography
```

---

## Command Line Options

```powershell
# Standard Install / Update
.\rmn-installer.ps1

# Update Configuration Only (skip binary copy)
.\rmn-installer.ps1 -ConfigOnly

# Force Reinstallation
.\rmn-installer.ps1 -Force
```

---

## License

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

GNU General Public License v3.0 - see [LICENSE](LICENSE) for details.
