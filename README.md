# Studio Display Brightness Tool (Windows)

Small PowerShell CLI for controlling monitor brightness through Windows monitor APIs (DDC/CI).

This is aimed at Apple Studio Display, but it can also control any external monitor that exposes brightness controls via `dxva2.dll`.

## File

- `tools/studio-display-brightness.ps1`

## Requirements

- Windows 10/11
- PowerShell 5.1+ or PowerShell 7+
- Monitor brightness controls available through DDC/CI (or equivalent monitor API support)

## Usage

Open PowerShell and run from this folder:

```powershell
# List monitor names and current brightness values
.\tools\studio-display-brightness.ps1 list

# Get brightness for monitor name containing "Studio Display"
.\tools\studio-display-brightness.ps1 get

# Set brightness to 55%
.\tools\studio-display-brightness.ps1 set 55

# Increase/decrease by amount
.\tools\studio-display-brightness.ps1 inc 10
.\tools\studio-display-brightness.ps1 dec 10

# Target another monitor name
.\tools\studio-display-brightness.ps1 get -MonitorName "DELL"

# Target by index (recommended when names are generic)
.\tools\studio-display-brightness.ps1 get -MonitorIndex 0
.\tools\studio-display-brightness.ps1 set 65 -MonitorIndex 0

# Apply to all brightness-capable monitors
.\tools\studio-display-brightness.ps1 set 40 -All
```

## Notes

- If `list` shows `no-brightness-control`, Windows cannot set brightness for that monitor through this API path.
- If `list` shows generic names, use `-MonitorIndex` from the `list` output for reliable targeting.
- Some USB-C/TB docks or adapters do not pass brightness control signals reliably.
- If Apple Studio Display is not controllable, try direct USB-C/Thunderbolt connection and update Windows graphics/monitor drivers.
