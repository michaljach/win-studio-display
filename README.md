# Apple Studio Display Brightness Control for Windows

Control **Apple Studio Display brightness on Windows** using a PowerShell CLI, a lightweight WinForms GUI, or a single-file EXE. This project talks directly to the display over **USB HID feature reports** (no DDC/CI dependency).

If you searched for terms like _studio display brightness windows_, _apple studio display windows brightness control_, or _studio display brightness powershell_, this is the tool.

## Preview

![Studio Display Brightness Windows GUI preview](docs/preview.png)

## Why this tool

- Direct HID brightness control for Apple Studio Display on Windows 10/11.
- Multiple ways to use it: CLI, `.cmd` wrappers, or GUI.
- GUI can be bundled into a distributable EXE with embedded backend logic.
- Auto-detects Apple HID endpoints and handles common Studio Display revisions.

## Quick start

```powershell
# List detected displays and current brightness
.\tools\studio-display-brightness.ps1 list

# Set brightness to 55%
.\tools\studio-display-brightness.ps1 set 55

# Open the Windows GUI
.\tools\studio-display-brightness-ui.ps1
```

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1+ or PowerShell 7+
- Apple Studio Display connected by USB-C / Thunderbolt

## Supported monitors

Known supported:

- Apple Studio Display (27-inch) over USB-C/Thunderbolt
- Apple Studio Display hardware revisions that expose Apple HID brightness report support (`VID_05AC`, commonly `PID 0x1114..0x1117`)

Compatibility-based support (detected automatically):

- Newer or variant Apple displays that expose the same HID brightness feature report
- Listings/search terms such as "Apple Studio Display XDR 2026" if the connected device reports compatible Apple HID brightness endpoints

Not yet verified in this repository:

- Apple Pro Display XDR (community testing welcome)

## Repository layout

- `tools/studio-display-brightness.ps1` - Core CLI backend.
- `tools/studio-display-brightness.cmd` - CMD launcher for CLI.
- `tools/studio-display-brightness-ui.ps1` - WinForms GUI.
- `tools/studio-display-brightness-ui.cmd` - CMD launcher for GUI.
- `tools/build-ui-exe.ps1` - Build script for standalone GUI EXE.

## CLI usage

```powershell
# List detected Studio Displays (serial + pid + interface + brightness)
.\tools\studio-display-brightness.ps1 list

# Get brightness
.\tools\studio-display-brightness.ps1 get

# Set brightness (0-100, optional % suffix)
.\tools\studio-display-brightness.ps1 set 55
.\tools\studio-display-brightness.ps1 set 55%

# Increase/decrease by step (1-100)
.\tools\studio-display-brightness.ps1 inc 10
.\tools\studio-display-brightness.ps1 dec 10

# Target by serial (recommended when available)
.\tools\studio-display-brightness.ps1 get -Serial "YOUR_SERIAL"
.\tools\studio-display-brightness.ps1 set 65 -Serial "YOUR_SERIAL"

# Target by list index (useful for automation/UI mapping)
.\tools\studio-display-brightness.ps1 get -Index 0
.\tools\studio-display-brightness.ps1 set 65 -Index 0
```

CMD wrapper equivalents:

```cmd
tools\studio-display-brightness.cmd list
tools\studio-display-brightness.cmd set 60
```

## Windows GUI

Launch GUI from PowerShell:

```powershell
.\tools\studio-display-brightness-ui.ps1
```

Or from CMD:

```cmd
tools\studio-display-brightness-ui.cmd
```

GUI includes:

- Display picker
- Brightness slider (0-100)
- Refresh button
- +/-10 quick step buttons
- Apply button

## Build standalone EXE

Run on Windows PowerShell:

```powershell
.\tools\build-ui-exe.ps1
```

Build output:

- `dist/StudioDisplayBrightnessUI.exe`

The backend script is embedded during build, so distribution can be a single executable.

## Technical details

HID behavior follows the same approach used by `himbeles/studi` / `asdbctl`:

- Vendor ID: `0x05AC` (Apple)
- Product ID/interface auto-detection with preference for known Studio Display combos (for example `PID 0x1114`, `MI_07`)
- HID report: 7 bytes (`report id 1` + 4-byte little-endian brightness + 2 padding bytes)
- Raw brightness range: `400..60000` mapped to `0..100%`

## Troubleshooting

- Generic monitor names in Windows settings are expected and do not block control.
- `list` shows `pid` and `mi` to help identify hardware/interface variants.
- If no display is found, test a direct connection (some docks/adapters block required HID paths).
- If execution-policy prompts appear, use the included `.cmd` launchers.

## Discoverability keywords

Apple Studio Display, Windows brightness control, Studio Display brightness tool, PowerShell HID monitor control, USB HID brightness CLI, WinForms Studio Display GUI.
