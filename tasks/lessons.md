# Lessons Learned

- When building Windows monitor tooling, never rely only on `PHYSICAL_MONITOR.szPhysicalMonitorDescription`; it can return generic labels. Always expose an index-based selector and attempt WMI friendly-name enrichment.
