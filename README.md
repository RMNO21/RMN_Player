# RMN-Player

A custom media player for Windows with pre-configured settings, custom icon, and modern UI.
<img width="1439" height="778" alt="image" src="https://github.com/user-attachments/assets/38ce66e9-d0ef-442f-a7a1-82cac28ed969" />
<img width="1440" height="810" alt="image" src="https://github.com/user-attachments/assets/b319ffc7-5657-4dad-9cf8-eb6fc8006321" />
<img width="1440" height="810" alt="image" src="https://github.com/user-attachments/assets/ae7127c6-56ef-4459-9f2a-805110f60309" />
<img width="1439" height="778" alt="image" src="https://github.com/user-attachments/assets/4238b586-d650-46d3-bcc9-d929ebe81262" />


## Features

- **Custom Application Icon** - Professional icon with full Alt+Tab and Explorer integration
- **Episode Tracker** - Track watched episodes, TV show progress, and resume position
- **Thumbnail Preview** - Hover over timeline for video previews
- **Modern UI** - Clean interface with uosc
- **Auto-Install/Update** - Configures player automatically
- **File Associations** - Sets RMN-Player as default for video and audio files
- **PATH Setup** - Add RMN-Player to system PATH for command-line use

## Requirements

- Windows 10/11 (64-bit)
- 7-Zip (automatically installed if missing)

## Setup

1. Run `Install-RMN.bat` as administrator

## What's Included

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

## Installation

### Fresh Install

1. Download or clone this repository
2. Right-click `Install-RMN.bat` and select "Run as administrator"
3. Follow the on-screen prompts

### Update RMN-Player

Run `Install-RMN.bat` - it will automatically detect and update your existing installation.

### Command Line

```powershell
# Install/Update
.\rmn-installer.ps1

# Config only
.\rmn-installer.ps1 -ConfigOnly

# Force reinstall (fresh start)
.\rmn-installer.ps1 -Force
```

## Key Bindings

| Key | Action |
|-----|--------|
| ENTER | Toggle fullscreen |
| LEFT/RIGHT | Seek 3 seconds |
| UP/DOWN | Adjust volume (5%) |
| m | Open menu (uosc) |
| c | Subtitles |
| a | Audio tracks |

### Menu Features (press `m`)

- **Subtitles** - Select and configure subtitle tracks
- **Audio tracks** - Select and configure audio tracks
- **Stream quality** - Change stream quality for online content
- **Playlist** - View and manage playlist
- **Chapters** - Navigate chapters
- **Navigation** - Next/Prev file, delete file, open file
- **Episode Tracker** - Episode status, TV show progress, mark watched/unwatched
- **Utils** - Aspect ratio, audio devices, screenshots, key bindings

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

## Uninstall

Run the uninstaller from Start Menu, or manually:

1. Delete `%LOCALAPPDATA%\RMN-Player\`
2. Delete `%APPDATA%\RMN-Player\`
3. Remove RMN-Player from PATH (optional)

## Troubleshooting

### Thumbnail not working

Run with `-ConfigOnly` flag to reconfigure:

```powershell
.\rmn-installer.ps1 -ConfigOnly
```

### Config not updating

Run with `-ConfigOnly` flag, or manually edit files in `%APPDATA%\RMN-Player\`.

### Icon not showing in Alt+Tab

The installer patches the player executable with a custom icon. If the icon doesn't appear:

1. Restart your computer
2. Run the installer again with `-Force` flag

## License

GNU General Public License v3.0 - see [LICENSE](LICENSE) for details.

## Credits

- [uosc](https://github.com/tomasklaen/uosc) - Modern UI framework
- [thumbfast](https://github.com/po5/thumbfast) - Thumbnail preview
- [autoload.lua](https://github.com/mpv-player/mpv) - Playlist autoloading
- [Resource Hacker](https://www.angusj.com/resourcehacker/) - PE resource editing
