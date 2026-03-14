# Studio Display Brightness Tool (Windows)

Small PowerShell CLI that directly controls **Apple Studio Display** brightness through USB HID feature reports.

It follows the same HID approach used by `himbeles/studi` / `asdbctl`:

- Vendor ID: `0x05AC` (Apple)
- Product ID/interface are auto-detected from Apple HID devices (prefers known Studio Display combos like `PID 0x1114`, `MI_07`)
- HID report: 7 bytes (`report id 1` + 4-byte little-endian brightness + 2 padding bytes)
- Raw brightness range: `400..60000` mapped to `0..100%`

## Files

- `tools/studio-display-brightness.ps1`
- `tools/studio-display-brightness.cmd`

## Requirements

- Windows 10/11
- PowerShell 5.1+ or PowerShell 7+
- Apple Studio Display connected through USB-C/Thunderbolt

## Usage

```powershell
# List detected Studio Displays (serial + pid + interface + brightness)
.\tools\studio-display-brightness.ps1 list

# Get brightness
.\tools\studio-display-brightness.ps1 get

# Set brightness (0-100)
.\tools\studio-display-brightness.ps1 set 55

# Increase/decrease by step (1-100)
.\tools\studio-display-brightness.ps1 inc 10
.\tools\studio-display-brightness.ps1 dec 10

# Target a specific display serial (optional)
.\tools\studio-display-brightness.ps1 get -Serial "YOUR_SERIAL"
.\tools\studio-display-brightness.ps1 set 65 -Serial "YOUR_SERIAL"
```

CMD wrapper:

```cmd
tools\studio-display-brightness.cmd list
tools\studio-display-brightness.cmd set 60
```

## Notes

- Generic monitor names in Windows settings are expected and do not affect this tool.
- `list` includes `pid` and `mi` so new hardware revisions can be identified quickly.
- If no device is found, try direct connection (some docks/adapters block the required HID path).
