# Task Plan

- [x] Design a minimal Windows GUI flow for brightness control backed by the existing CLI script.
- [x] Implement a PowerShell WinForms UI app with slider, refresh, and apply controls.
- [x] Add Windows launcher and an EXE build script (`ps2exe`) that outputs a distributable executable.
- [x] Update README with GUI usage and EXE build steps.
- [x] Verify script integrity (best-effort in current environment) and document results.

## Review

- Added `tools/studio-display-brightness-ui.ps1` with a simple WinForms UI (display picker, slider, refresh, +/-10, apply).
- Added `tools/studio-display-brightness-ui.cmd` launcher and `tools/build-ui-exe.ps1` to generate `dist/StudioDisplayBrightnessUI.exe` via `ps2exe`.
- Extended backend CLI with `-Index` targeting to support reliable UI selection.
- Updated `README.md` with GUI usage and EXE build instructions.
- Runtime validation could not be executed in this environment because Windows PowerShell is unavailable; static review completed.
