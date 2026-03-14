# Task Plan

- [x] Design a minimal Windows GUI flow for brightness control backed by the existing CLI script.
- [x] Implement a PowerShell WinForms UI app with slider, refresh, and apply controls.
- [x] Add Windows launcher and an EXE build script (`ps2exe`) that outputs a distributable executable.
- [x] Update README with GUI usage and EXE build steps.
- [x] Make EXE runtime path resolution robust when `$PSScriptRoot` is empty.
- [x] Embed backend logic into the generated EXE so distribution is a single file.
- [x] Fix EXE startup path error caused by empty base-path candidate expansion.
- [x] Fix embedded backend invocation so named params are not mis-bound as positional args.
- [x] Add backend compatibility parsing for legacy positional `get -Index` token calls.
- [x] Run embedded backend via temp script file to guarantee parameter binding parity with external script execution.
- [x] Verify script integrity (best-effort in current environment) and document results.

## Review

- Added `tools/studio-display-brightness-ui.ps1` with a simple WinForms UI (display picker, slider, refresh, +/-10, apply).
- Added `tools/studio-display-brightness-ui.cmd` launcher and `tools/build-ui-exe.ps1` to generate `dist/StudioDisplayBrightnessUI.exe` via `ps2exe`.
- Extended backend CLI with `-Index` targeting to support reliable UI selection.
- Updated `README.md` with GUI usage and EXE build instructions.
- UI backend discovery now checks multiple runtime base directories (including `System.AppContext.BaseDirectory`) to work from compiled EXE launches.
- EXE build now embeds backend script content directly into the compiled UI executable; no sidecar backend file is required.
- UI path discovery now ignores empty normalized paths and supports embedded backend variable lookup from both script and global scopes.
- UI backend calls now invoke the embedded script with explicit named parameters (hashtable splat), fixing `-Index` being cast into positional `Value`.
- Backend parser now accepts legacy positional `get -Index N` patterns and rewrites them to named index selection before validation.
- Embedded backend execution now materializes to a temp `.ps1` and invokes that path, eliminating scriptblock binding edge cases seen in the EXE.
- Runtime validation could not be executed in this environment because Windows PowerShell is unavailable; static review completed.
