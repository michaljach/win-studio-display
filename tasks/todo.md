# Task Plan

- [x] Reproduce issue context: `list` can surface generic monitor names like PnP/P2P.
- [x] Improve monitor identification output with stable monitor index and better friendly names.
- [x] Update targeting logic so brightness commands can select monitors by index.
- [x] Update README usage/troubleshooting for generic-name scenarios.
- [x] Verify script integrity (best-effort in current environment) and document results.

## Review

- Added `-MonitorIndex` selection path so generic monitor labels are no longer a blocker.
- Enriched `list` output with index and WMI-derived friendly names when available.
- Could not run runtime validation in this environment because Windows PowerShell is unavailable on host; changes were validated via static review.
