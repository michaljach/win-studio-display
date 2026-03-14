# Task Plan

- [x] Investigate why newly released Studio Display XDR is not detected by strict PID/interface filters.
- [x] Relax HID discovery to scan all Apple HID devices and auto-select brightness-capable endpoints.
- [x] Surface `pid` and `mi` in `list` output for hardware diagnostics.
- [x] Update README for adaptive hardware detection behavior.
- [x] Improve HID open/probe strategy to handle endpoints that reject read-write opens during discovery.
- [x] Eliminate persistent `Add-Type` collisions by compiling native helper types with unique per-run names.
- [x] Verify script integrity (best-effort in current environment) and document results.

## Review

- Discovery no longer hard-fails on a single product/interface pair; the script now enumerates all Apple HID devices and probes brightness feature report support.
- Selection prefers known Studio Display IDs/interfaces but falls back to any Apple HID endpoint that accepts report id 1 and returns brightness.
- `list` now prints `pid` and `mi` to help diagnose newly released hardware revisions.
- HID probing now uses best-effort handle opening (read/write then zero-access) and path VID/PID parsing fallback when HID attributes are unavailable.
- Native C# helper types now use unique names per script execution, avoiding duplicate type-name errors in reused PowerShell sessions.
- Could not run runtime validation in this environment because Windows PowerShell is unavailable on host; changes were validated via static review.
