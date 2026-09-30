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
- [x] Execute backend via child PowerShell process to guarantee CLI-equivalent argument parsing from EXE.
- [x] Force backend `-Value` to be passed as named CLI arg from UI child process.
- [x] Fix native-process argument splatting and add executed-command diagnostics to backend error output.
- [x] Update UI selector strategy to prefer serial targeting and avoid index-only routing for single-display setups.
- [x] Pass backend `-Command` as named argument in UI child-process invocation.
- [x] Ensure embedded backend variable lookup also checks local scope and remove stale sidecar backend after EXE builds.
- [x] Add user-visible error modal and temp log output with full backend command diagnostics.
- [x] Simplify UI backend invocation to direct script-path call with named splatted parameters.
- [x] Align UI backend invocation with literal CLI token order for set/get paths.
- [x] Add backend tolerance for raw brightness numeric inputs in `set` path.
- [x] Route UI Apply through `inc/dec` delta commands to avoid fragile `set` binding paths.
- [x] Add UI build-id and backend invocation logging to prove which executable code path is running.
- [x] Restore `set` as primary UI apply path with `inc/dec` fallback only on failure.
- [x] Remove index pinning for unknown-serial UI selections to match CLI endpoint targeting behavior.
- [x] Chunk fallback `inc/dec` deltas to 1..100 steps and clamp parsed `get` values.
- [x] Normalize backend `inc/dec` inputs to 1..100 to prevent residual validation failures.
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
- UI now invokes backend through a child `powershell.exe`/`pwsh.exe` process with explicit CLI args, matching real command-line behavior and avoiding in-runspace binding quirks.
- UI child-process invocation now passes `-Value` explicitly as a named argument for `set`, removing remaining positional parsing ambiguity.
- Native child-process invocation now uses variable-array splatting (`@nativeArgs`) and appends the exact executed command line when backend returns non-zero.
- UI now prefers `-Serial` targeting when available and only uses `-Index` if multiple unnamed displays exist, aligning behavior with successful CLI usage.
- UI child-process invocation now also passes backend `-Command` explicitly as named argument to remove command-position ambiguity.
- Embedded backend discovery now checks default/local scope in addition to script/global, and EXE build now deletes old `dist/studio-display-brightness.ps1` sidecars that could override intended behavior.
- UI now shows full backend errors in a dialog and logs them to `%TEMP%\studio-display-brightness-ui.log` for precise troubleshooting.
- UI backend calls now execute the backend script path directly with named splatted parameters, reducing host argument parsing edge cases.
- UI backend call construction now mirrors manual CLI token order (`set <value> ...`), matching the known-working command-line behavior.
- Backend `set` now accepts raw-style numeric values (400..60000 and 0..65535) and converts them to percent before validation, preventing false out-of-range errors.
- UI Apply now computes target delta and uses backend `inc`/`dec` commands instead of `set`, bypassing the persistent `set` argument-binding failure in EXE-hosted runs.
- UI now includes build id `2026-03-14.1` in title and logs every backend invocation/output to `%TEMP%\studio-display-brightness-ui.log` to detect stale EXE usage.
- UI Apply now attempts backend `set` first (matching working CLI behavior) and only falls back to `inc/dec` delta if `set` throws.
- UI selector mapping now uses `-Serial` when available, otherwise no selector (no `-Index`), so backend handles unknown-serial endpoint selection the same way as working CLI commands.
- Fallback `inc/dec` now runs in chunks of max 100 to satisfy backend step validation and clamps parsed `get` brightness into 0..100 before delta math.
- Backend now normalizes `inc/dec` values into 1..100 (including raw-style conversions) before execution, eliminating the `dec value must be between 1 and 100` throw path.
- Runtime validation could not be executed in this environment because Windows PowerShell is unavailable; static review completed.

## 2026-03-14 Percentage Apply Bug

- [x] Reproduce and trace the value-validation path that surfaces the 1..100 range error.
- [x] Implement a parser fix so percentage-form inputs are treated as numeric values.
- [x] Verify behavior with available checks and document any environment limitations.

## 2026-03-14 Percentage Apply Bug Review

- Root cause: backend value parsing only accepted strict integers; percentage-form inputs (for example `55%`) failed validation before command execution and surfaced the range error.
- Fix: backend now supports optional trailing `%`, parses numeric values more robustly, and preserves raw-value conversion only for non-percent inputs.
- Verification: static diff review completed and parsing/control-flow paths validated by inspection; runtime verification is blocked in this environment because PowerShell is not installed.

## 2026-03-15 README + GitHub SEO

- [x] Refresh `README.md` copy and structure to improve keyword coverage and discoverability.
- [x] Add explicit discoverability keywords and usage wording for CLI/UI/EXE entry points.
- [x] Update GitHub repository description and topic tags for better search relevance.
- [x] Verify repository diff and document outcomes in this file.

## 2026-03-15 README + GitHub SEO Review

- Updated `README.md` headline, intro, quick start, and section wording to better match common search intents for Studio Display brightness control on Windows.
- Added discoverability-focused terminology and clarified CLI, GUI, and EXE entry points to improve tool findability.
- Updated GitHub repo description to: `Control Apple Studio Display brightness on Windows with a PowerShell CLI, WinForms GUI, and single-file EXE via native USB HID feature reports.`
- Added GitHub topics: `apple-studio-display`, `studio-display`, `brightness-control`, `windows`, `powershell`, `usb-hid`, `monitor-control`, `winforms`, `cli-tool`, `ps2exe`.
- Verified both README diff and live GitHub metadata via `gh repo view`.

## 2026-03-17 Startup Brightness Sync

- [x] Confirm current UI startup flow and identify where startup brightness sync should run.
- [x] Update UI startup behavior to read display brightness and apply it on app launch.
- [x] Verify updated script logic via static review and document any runtime limitations.

## 2026-09-30 Native Windows Brightness Driver

- [x] Identify how Windows 11 discovers brightness-capable displays (monitor.sys interface `{DB524086...}` + Display Enhancement Service private IOCTLs 0x234004..0x234010, plus public `IOCTL_PANEL_*`).
- [x] Confirm the Studio Display HID Monitor Control collection layout (report 1: VESA brightness in 0.01 nit, 400..60000; duration in ms).
- [x] Implement a KMDF Monitor-class upper filter (`driver/src`) that services those requests over HID feature reports.
- [x] Add a VS-free build (WDK/SDK NuGet + portable LLVM) with test signing, install/uninstall scripts with automatic rollback, and a test tool.
- [ ] Runtime verification on hardware (needs Secure Boot off + test signing + elevation).

## 2026-09-30 Production Driver Package

- [x] Replace registry/sc.exe install with an extension INF (`*PNP09FF`, `AddFilter` upper, DIRID 13, per-arch sections) that passes `InfVerif /h`.
- [x] Build x64 + ARM64 with /GS, CFG, /WX, version resource; verify HVCI compatibility on every build; generate catalog with Inf2Cat.
- [x] Leave monitors with native backlight control (e.g. Boot Camp panels) to monitor.sys; panel IOCTLs kernel-only like monitor.sys.
- [x] Add Partner Center submission CAB tooling (EV signing + timestamp), Microsoft-signature-verified release zip, pnputil install/uninstall with rollback, CI workflow.
- [ ] Organization: EV certificate + Hardware Developer Program registration, then attestation or WHCP submission.
- [ ] Hardware test pass (checklist in driver/README.md) before the first submission.

## 2026-09-30 First Hardware Load

- [x] Fix `install.ps1`/`uninstall.ps1` crashing under StrictMode when the monitor class has no `UpperFilters` value.
- [x] Fix driver load failure (`CM_PROB_DRIVER_FAILED_LOAD`, `0xC0000018` STATUS_CONFLICTING_ADDRESSES): lld-link sets `IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE` by default and the kernel loader refuses such images. Isolated with standalone `sc start` loads of a minimal driver; `/TSAWARE:NO` alone fixes it, `/FILEALIGN:4096` alone doesn't.
- [x] Also fixed: `/SECTION:INIT,d` in lld replaces attributes (INIT was non-executable) → `INIT,erd`; KMDF context type info moved to `.rdata` (clang emitted a second, read-only `.data`). build.ps1 now rejects TS-aware images, non-executable code sections and duplicate section names.
- [x] Verified on Studio Display (Win 11 26300, x64, signature enforcement disabled for the boot): driver running, brightness interface registered, `test-driver.ps1` get/set 600 → 200 → 600 nits.
- [x] Settings / Quick Settings slider: does NOT appear. Root cause found (below); the monitor-filter design can't produce it for an external display.

## 2026-09-30 Why there is no slider (reverse-engineered on build 26300)

- DES (`Microsoft.Graphics.Display.DisplayEnhancementService.dll`) builds a `MonitorAdapterImpl` per `Windows.Devices.Display.DisplayMonitor`.
  - `GetIsSystemBrightnessMonitor` = `ConnectionKind == Internal` && brightness support != None. This is the only path that uses the `{DB524086…}\brightness` IOCTLs our driver answers.
  - `GetIsExternalBrightnessMonitor` = `ConnectionKind != Internal` && support != None. It sets brightness through `ColorManagerSetBrightness`, not our interface, and is gated by WIL feature `ExternalBrightness` (ID 12759424, disabled at priority 9 on this machine).
- Brightness support comes from `DisplayMonitor::CopyBrightnessDataFromMonitorInternalInfo(DISPLAYCONFIG_GET_MONITOR_INTERNAL_INFO)`, i.e. from dxgkrnl per display target. dxgkrnl has its own switch, `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\ExternalBrightnessEnabled` (not set), and `MonitorGetExternalBrightnessPolicy`. Neither dxgkrnl nor win32k references the monitor.sys brightness interface.
- The GPU reports the Studio Display as a wired external monitor, so DES never uses our interface. Enabling `ExternalBrightness` at runtime alone didn't produce a slider.
- Option 1 tested and abandoned: rebooted with `ExternalBrightnessEnabled = 1` set before boot, then re-enabled `ExternalBrightness` (priority 10, state 2, status 0) and restarted DES. Still no slider. Likely cause: Windows' external brightness path is DDC/CI-based, and the Studio Display takes brightness only over USB HID. Registry value removed with `enable-external-brightness.ps1 -Revert`.
- Direction chosen: user-mode tray app (below). The driver stays in the repo as an experiment.

## 2026-09-30 Tray App

- [x] C# WinForms tray app in `tray/src`, built by `tray/build.ps1` with the in-box .NET Framework 4.8 `csc.exe` (no SDK); AnyCPU, PerMonitorV2 manifest, `/warnaserror+`.
- [x] HID I/O on one worker thread; slider writes coalesced per display (only the newest value is sent). Endpoint selection matches the CLI; endpoints grouped by serial.
- [x] Windows 11-style flyout (custom slider, theme + accent from registry, DWM rounded corners), OSD for hotkeys, sun tray icon drawn to match the taskbar theme. EXE icon rendered from the same code at build time.
- [x] Hotkeys (default Ctrl+Alt+PageUp/PageDown, step 5, configurable in `%APPDATA%\StudioDisplayBrightness\settings.ini`, reloaded on save).
- [x] Last brightness per serial in `HKCU\Software\StudioDisplayBrightness\Brightness`; restored on app start and when a display appears (debounced `DBT_DEVNODES_CHANGED`, resume). "Start with Windows" via HKCU Run.
- [x] Fixed CLI `set` rejecting 2x..9x values (string comparison on `[string]$Value`).
- [ ] Activation from a real tray click (flyout seen live only via second-instance launch).
- [ ] Hot-plug restore (unplug/replug the display) on hardware.

- [x] Released as `v2026.09.30` (EXE asset).
- [x] Removed the old PowerShell GUI (`tools/studio-display-brightness-ui.*`, `tools/build-ui-exe.ps1`); README rewritten around the tray app with a latest-release download link and new screenshots (`docs/tray-flyout.png`, `docs/hotkey-osd.png`, captured live and corner-masked).
- [x] Live flyout checked on hardware (DWM rounded corners, 150%).

## 2026-09-30 Tray App Review

- Hardware (Studio Display, Win 11 26300, 150%): display found (1 endpoint, serial `...401C`); hotkey path 100% → 90% → 100% confirmed with the CLI, value saved to HKCU; restore-on-start put 95% (set by CLI while the app was stopped) back to 100%. ~32 MB working set.
- `StudioDisplayBrightness.exe --render-preview <dir>` writes flyout/OSD PNGs (dark/light, 1 and 2 displays, empty state) at 150%.
- The flyout couldn't be seen live because a fullscreen game had the foreground; that also showed the flyout never receives Deactivate when activation is refused, so it now also closes once the cursor leaves it.
- The HID product string of the brightness endpoint is "HID Relay", so the UI names displays "Studio Display" (+ serial suffix when several are connected).

## 2026-03-17 Startup Brightness Sync Review

- Updated `tools/studio-display-brightness-ui.ps1` startup flow with `Sync-StartupBrightness`, which reads the selected display brightness on launch, applies that value back to the display, then refreshes UI state.
- Wired startup sync into the form shown event so the behavior runs automatically when the app opens.
- Bumped UI build id to `2026-03-17.1` and documented startup-sync behavior in `README.md`.
- Runtime verification is not possible in this environment because PowerShell/WinForms are unavailable on macOS; changes were validated by static code review.
