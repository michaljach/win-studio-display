# Lessons Learned

- When building Windows monitor tooling, never rely only on `PHYSICAL_MONITOR.szPhysicalMonitorDescription`; it can return generic labels. Always expose an index-based selector and attempt WMI friendly-name enrichment.
- For Apple Studio Display specifically, default to HID control (`VID_05AC`, `PID_1114`) instead of DDC/CI monitor APIs; generic PnP names are a symptom of using the wrong control path.
- When the user asks to "do the same in our script," implement the external project's core logic directly rather than wrapping/downloading their binary.
- Do not hardcode a single product/interface tuple for Apple displays; probe all Apple HID devices for brightness report support to handle new hardware revisions.
