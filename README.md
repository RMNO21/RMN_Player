<div align="center">

# RMN-Player

A custom media player for Windows with pre-configured settings, custom icon, and modern UI.

</div>

---

## Screenshots

<table border="0">
  <tr>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/38ce66e9-d0ef-442f-a7a1-82cac28ed969" alt="RMN-Player Main UI" width="400"/>
      <p>Main Interface with uosc Menu</p>
    </td>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/b319ffc7-5657-4dad-9cf8-eb6fc8006321" alt="RMN-Player Thumbnail Preview" width="400"/>
      <p>Video Playback with Thumbnail Preview</p>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/ae7127c6-56ef-4459-9f2a-805110f60309" alt="RMN-Player Audio Subtitle Settings" width="400"/>
      <p>Audio & Subtitle Track Settings</p>
    </td>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/4238b586-d650-46d3-bcc9-d929ebe81262" alt="RMN-Player Playlist" width="400"/>
      <p>Playlist & Episode Tracker</p>
    </td>
  </tr>
</table>

---

## Features

| Feature | Description |
|---------|-------------|
| True Darkness| Professional Light Adjustment had been Set|
| Episode Tracker | Track watched episodes, TV show progress, and resume position |
| Thumbnail Preview | Hover over timeline for video previews |
| Modern UI | Clean interface with uosc |
| Auto-Install | Configures player automatically |
| File Associations | Sets RMN-Player as default for video and audio files |
| PATH Setup | Add RMN-Player to system PATH for command-line use |

---

## Quick Start

### Requirements
- Windows 10/11 (64-bit)
- 7-Zip (automatically installed if missing)

### Installation

1. Clone or download this repository
2. Run `Install-RMN.bat` as administrator
3. Follow the on-screen prompts

```powershell
# Or use command line
.\rmn-installer.ps1
```

---

## Key Bindings

| Key | Action |
|-----|--------|
| `ENTER` | Toggle fullscreen |
| `LEFT/RIGHT` | Seek 3 seconds |
| `UP/DOWN` | Adjust volume (5%) |
| `m` | Open menu (uosc) |
| `c` | Subtitles |
| `a` | Audio tracks |

---

## Menu Features

Press `m` to open the menu:

- **Subtitles** - Select and configure subtitle tracks
- **Audio tracks** - Select and configure audio tracks
- **Stream quality** - Change stream quality for online content
- **Playlist** - View and manage playlist
- **Chapters** - Navigate chapters
- **Navigation** - Next/Prev file, delete file, open file
- **Episode Tracker** - Episode status, TV show progress, mark watched/unwatched
- **Utils** - Aspect ratio, audio devices, screenshots, key bindings

---

## Configuration

All config files are stored at `%APPDATA%\RMN-Player\`:

```
%APPDATA%\RMN-Player\
├── player.conf            # Main configuration
├── input.conf             # Key bindings
├── episode-tracker.json   # Episode tracking database
├── script-opts/
│   ├── thumbfast.conf     # Thumbnail settings
│   ├── uosc.conf          # UI settings
│   └── autoload.conf      # Playlist settings
├── scripts/
│   ├── thumbfast.lua      # Thumbnail engine
│   ├── autoload.lua       # Auto-load playlist
│   ├── episode-tracker.lua
│   ├── save-position.lua
│   └── uosc/              # Modern UI
└── fonts/                 # UI fonts
```

---

## Project Structure

```
rmn-installer/
├── Install-RMN.bat        # Run as admin to install
├── rmn-installer.ps1      # Main installer script
├── uninstall.ps1          # Uninstaller
├── config/                # Player configuration
│   ├── player.conf        # Video settings
│   ├── input.conf         # Keybindings
│   ├── rmn-icon.ico       # Custom app icon
│   ├── scripts/           # uosc, thumbfast, episode tracker
│   └── script-opts/       # Script settings
├── player/                # Bundled player binaries
└── tools/                 # ResourceHacker (for icon patching)
```

---

## Command Line Options

```powershell
# Install/Update
.\rmn-installer.ps1

# Config only (skip player download)
.\rmn-installer.ps1 -ConfigOnly

# Force reinstall (fresh start)
.\rmn-installer.ps1 -Force
```

---

## Uninstall

Run the uninstaller from Start Menu, or manually:

1. Delete `%LOCALAPPDATA%\RMN-Player\`
2. Delete `%APPDATA%\RMN-Player\`
3. Remove RMN-Player from PATH (optional)

---

## Troubleshooting

<details>
<summary><b>Thumbnail not working</b></summary>

Run with `-ConfigOnly` flag to reconfigure:

```powershell
.\rmn-installer.ps1 -ConfigOnly
```
</details>

<details>
<summary><b>Config not updating</b></summary>

Run with `-ConfigOnly` flag, or manually edit files in `%APPDATA%\RMN-Player\`.
</details>

<details>
<summary><b>Icon not showing in Alt+Tab</b></summary>

The installer patches the player executable with a custom icon. If the icon doesn't appear:

1. Restart your computer
2. Run the installer again with `-Force` flag
</details>

---

## License

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

GNU General Public License v3.0 - see [LICENSE](LICENSE) for details.

---

## Credits

- [uosc](https://github.com/tomasklaen/uosc) - Modern UI framework
- [thumbfast](https://github.com/po5/thumbfast) - Thumbnail preview
- [autoload.lua](https://github.com/mpv-player/mpv) - Playlist autoloading
- [Resource Hacker](https://www.angusj.com/resourcehacker/) - PE resource editing

---

<div align="center">

**Made with ❤️ for media enthusiasts**

</div>
