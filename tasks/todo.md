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

## 2026-03-17 Startup Brightness Sync Review

- Updated `tools/studio-display-brightness-ui.ps1` startup flow with `Sync-StartupBrightness`, which reads the selected display brightness on launch, applies that value back to the display, then refreshes UI state.
- Wired startup sync into the form shown event so the behavior runs automatically when the app opens.
- Bumped UI build id to `2026-03-17.1` and documented startup-sync behavior in `README.md`.
- Runtime verification is not possible in this environment because PowerShell/WinForms are unavailable on macOS; changes were validated by static code review.
