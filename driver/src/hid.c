/*
 * StudioDisplayBrightness - HID Monitor Control Class endpoint discovery and
 * feature report I/O.
 *
 * A usable endpoint is a HID top-level collection with usage
 * Monitor (0x80) / Monitor Control (0x01) whose feature reports carry
 * VESA Virtual Controls (0x82) / Brightness (0x10). Apple displays also put
 * a Physical Input Device (0x0F) / Duration (0x50) value in the same report,
 * which the display uses as the ramp time in milliseconds.
 *
 * All functions here run at PASSIVE_LEVEL with SdbGlobals.Lock held.
 */
#include "sdb.h"

#define SDB_LOG(fmt, ...) \
    DbgPrintEx(DPFLTR_IHVVIDEO_ID, DPFLTR_INFO_LEVEL, "StudioDisplayBrightness: " fmt "\n", __VA_ARGS__)

/* --------------------------------------------------------------------------
 * Unit conversion
 * -------------------------------------------------------------------------- */

/* Returns TRUE when the HID unit is luminance (cd/m^2 or the cd/cm^2 that
 * displays report while meaning cd/m^2) and yields the power of ten that
 * converts one logical unit into millinits. */
static BOOLEAN
SdbLuminanceScale(
    _In_ ULONG Units,
    _In_ ULONG UnitsExp,
    _Out_ PLONG Scale
    )
{
    ULONG system = Units & 0xF;
    ULONG length = (Units >> 4) & 0xF;
    ULONG luminous = (Units >> 24) & 0xF;
    ULONG others = Units & 0x00FFFF00;
    LONG exponent = (LONG)(UnitsExp & 0xF);

    *Scale = 0;

    if ((system != 1 && system != 2) || length != 0xE || luminous != 1 || others != 0) {
        return FALSE;
    }

    if (exponent >= 8) {
        exponent -= 16;
    }

    *Scale = exponent + 3;
    return *Scale >= -6 && *Scale <= 6;
}

static ULONG
SdbScale(
    _In_ LONG Value,
    _In_ LONG Scale
    )
{
    ULONGLONG result = Value < 0 ? 0 : (ULONGLONG)Value;
    LONG i;

    for (i = 0; i < Scale; i++) {
        result *= 10;
    }
    for (i = 0; i > Scale; i--) {
        result /= 10;
    }

    return result > MAXULONG ? MAXULONG : (ULONG)result;
}

static ULONG
SdbMulDivRound(
    _In_ ULONGLONG Value,
    _In_ ULONGLONG Multiplier,
    _In_ ULONGLONG Divisor
    )
{
    if (Divisor == 0) {
        return 0;
    }
    return (ULONG)((Value * Multiplier + Divisor / 2) / Divisor);
}

static LONG
SdbMillinitsToLogical(
    _In_ PSDB_ENDPOINT Ep,
    _In_ ULONG Millinits
    )
{
    ULONG span = Ep->MaxMillinits - Ep->MinMillinits;

    if (Millinits <= Ep->MinMillinits) {
        return Ep->LogicalMin;
    }
    if (Millinits >= Ep->MaxMillinits) {
        return Ep->LogicalMax;
    }

    return Ep->LogicalMin + (LONG)SdbMulDivRound(
        Millinits - Ep->MinMillinits, (ULONG)(Ep->LogicalMax - Ep->LogicalMin), span);
}

static ULONG
SdbLogicalToMillinits(
    _In_ PSDB_ENDPOINT Ep,
    _In_ LONG Logical
    )
{
    if (Logical <= Ep->LogicalMin) {
        return Ep->MinMillinits;
    }
    if (Logical >= Ep->LogicalMax) {
        return Ep->MaxMillinits;
    }

    return Ep->MinMillinits + SdbMulDivRound(
        (ULONG)(Logical - Ep->LogicalMin),
        Ep->MaxMillinits - Ep->MinMillinits,
        (ULONG)(Ep->LogicalMax - Ep->LogicalMin));
}

ULONG
SdbPercentToMillinits(
    _In_ PSDB_ENDPOINT Ep,
    _In_ ULONG Percent
    )
{
    if (Percent > 100) {
        Percent = 100;
    }
    return Ep->MinMillinits + SdbMulDivRound(Percent, Ep->MaxMillinits - Ep->MinMillinits, 100);
}

/* --------------------------------------------------------------------------
 * HID I/O helpers
 * -------------------------------------------------------------------------- */

static NTSTATUS
SdbSendIoctl(
    _In_ WDFIOTARGET Target,
    _In_ ULONG Code,
    _In_reads_bytes_opt_(InLength) PVOID In,
    _In_ ULONG InLength,
    _Out_writes_bytes_opt_(OutLength) PVOID Out,
    _In_ ULONG OutLength,
    _Out_opt_ PULONG_PTR BytesReturned
    )
{
    WDF_MEMORY_DESCRIPTOR inDesc;
    WDF_MEMORY_DESCRIPTOR outDesc;
    WDF_REQUEST_SEND_OPTIONS options;

    if (In != NULL) {
        WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&inDesc, In, InLength);
    }
    if (Out != NULL) {
        WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&outDesc, Out, OutLength);
    }

    WDF_REQUEST_SEND_OPTIONS_INIT(&options, 0);
    WDF_REQUEST_SEND_OPTIONS_SET_TIMEOUT(&options, WDF_REL_TIMEOUT_IN_MS(SDB_HID_TIMEOUT_MS));

    return WdfIoTargetSendIoctlSynchronously(
        Target, NULL, Code,
        In != NULL ? &inDesc : NULL,
        Out != NULL ? &outDesc : NULL,
        &options, BytesReturned);
}

static NTSTATUS
SdbOpenTarget(
    _In_ WDFIOTARGET Target,
    _In_ PCUNICODE_STRING SymbolicLink,
    _In_ ACCESS_MASK Access,
    _In_ BOOLEAN WatchRemoval
    )
{
    WDF_IO_TARGET_OPEN_PARAMS params;

    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(&params, SymbolicLink, Access);
    params.ShareAccess = FILE_SHARE_READ | FILE_SHARE_WRITE;
    if (WatchRemoval) {
        params.EvtIoTargetRemoveComplete = SdbEvtTargetRemoveComplete;
    }

    return WdfIoTargetOpen(Target, &params);
}

static BOOLEAN
SdbParseHexToken(
    _In_ PCUNICODE_STRING String,
    _In_ PCWSTR Marker,
    _Out_ PUSHORT Value
    )
{
    USHORT count = String->Length / sizeof(WCHAR);
    USHORT markerLength = (USHORT)wcslen(Marker);
    USHORT i;
    USHORT j;

    *Value = 0;

    for (i = 0; i + markerLength + 4 <= count; i++) {
        BOOLEAN match = TRUE;

        for (j = 0; j < markerLength; j++) {
            if (RtlUpcaseUnicodeChar(String->Buffer[i + j]) != Marker[j]) {
                match = FALSE;
                break;
            }
        }
        if (!match) {
            continue;
        }

        for (j = 0; j < 4; j++) {
            WCHAR c = RtlUpcaseUnicodeChar(String->Buffer[i + markerLength + j]);
            USHORT digit;

            if (c >= L'0' && c <= L'9') {
                digit = (USHORT)(c - L'0');
            } else if (c >= L'A' && c <= L'F') {
                digit = (USHORT)(c - L'A' + 10);
            } else {
                return FALSE;
            }
            *Value = (USHORT)((*Value << 4) | digit);
        }
        return TRUE;
    }

    return FALSE;
}

static VOID
SdbFreeEndpoint(
    _In_ _Post_invalid_ PSDB_ENDPOINT Ep
    )
{
    if (Ep->Target != NULL) {
        WdfObjectDelete(Ep->Target);
    }
    if (Ep->Preparsed != NULL) {
        ExFreePoolWithTag(Ep->Preparsed, SDB_POOL_TAG);
    }
    if (Ep->SymbolicLink.Buffer != NULL) {
        ExFreePoolWithTag(Ep->SymbolicLink.Buffer, SDB_POOL_TAG);
    }
    ExFreePoolWithTag(Ep, SDB_POOL_TAG);
}

/* --------------------------------------------------------------------------
 * Probing
 * -------------------------------------------------------------------------- */

static NTSTATUS
SdbReadRawBrightness(
    _In_ PSDB_ENDPOINT Ep,
    _Out_ PLONG Raw
    )
{
    PCHAR report;
    ULONG value = 0;
    NTSTATUS status;

    *Raw = 0;

    report = ExAllocatePool2(POOL_FLAG_NON_PAGED, Ep->FeatureReportLength, SDB_POOL_TAG);
    if (report == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    report[0] = (CHAR)Ep->ReportId;
    status = SdbSendIoctl(Ep->Target, IOCTL_HID_GET_FEATURE, NULL, 0, report, Ep->FeatureReportLength, NULL);
    if (NT_SUCCESS(status)) {
        status = HidP_GetUsageValue(
            HidP_Feature, SDB_USAGE_PAGE_VESA_VIRTUAL, 0, SDB_USAGE_VESA_BRIGHTNESS,
            &value, Ep->Preparsed, report, Ep->FeatureReportLength);
        if (status == HIDP_STATUS_SUCCESS) {
            status = STATUS_SUCCESS;
            *Raw = (LONG)value;
        } else {
            status = STATUS_UNSUCCESSFUL;
        }
    }

    ExFreePoolWithTag(report, SDB_POOL_TAG);
    return status;
}

static NTSTATUS
SdbProbeEndpoint(
    _In_ PSDB_DEVICE_CONTEXT Ctx,
    _In_ PCUNICODE_STRING SymbolicLink,
    _In_ USHORT VendorId,
    _In_ USHORT ProductId,
    _Outptr_ PSDB_ENDPOINT* Endpoint
    )
{
    WDF_OBJECT_ATTRIBUTES attributes;
    HID_COLLECTION_INFORMATION info;
    HIDP_CAPS caps;
    HIDP_VALUE_CAPS brightness;
    HIDP_VALUE_CAPS duration;
    USHORT count;
    PSDB_ENDPOINT ep;
    LONG scale;
    LONG raw;
    NTSTATUS status;

    *Endpoint = NULL;

    ep = ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(*ep), SDB_POOL_TAG);
    if (ep == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    ep->VendorId = VendorId;
    ep->ProductId = ProductId;

    ep->SymbolicLink.Buffer = ExAllocatePool2(POOL_FLAG_NON_PAGED, SymbolicLink->Length, SDB_POOL_TAG);
    if (ep->SymbolicLink.Buffer == NULL) {
        status = STATUS_INSUFFICIENT_RESOURCES;
        goto Fail;
    }
    RtlCopyMemory(ep->SymbolicLink.Buffer, SymbolicLink->Buffer, SymbolicLink->Length);
    ep->SymbolicLink.Length = SymbolicLink->Length;
    ep->SymbolicLink.MaximumLength = SymbolicLink->Length;

    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = Ctx->Device;
    status = WdfIoTargetCreate(Ctx->Device, &attributes, &ep->Target);
    if (!NT_SUCCESS(status)) {
        ep->Target = NULL;
        goto Fail;
    }

    /* Read the report descriptor without requesting data access, the same
     * way hid.dll enumerates devices, so unrelated collections owned by
     * other drivers are left alone. */
    status = SdbOpenTarget(ep->Target, &ep->SymbolicLink, FILE_READ_ATTRIBUTES | SYNCHRONIZE, FALSE);
    if (!NT_SUCCESS(status)) {
        goto Fail;
    }

    RtlZeroMemory(&info, sizeof(info));
    status = SdbSendIoctl(ep->Target, IOCTL_HID_GET_COLLECTION_INFORMATION, NULL, 0, &info, sizeof(info), NULL);
    if (!NT_SUCCESS(status) || info.DescriptorSize == 0 || info.DescriptorSize > 0x100000) {
        status = NT_SUCCESS(status) ? STATUS_DEVICE_CONFIGURATION_ERROR : status;
        goto Fail;
    }

    ep->Preparsed = ExAllocatePool2(POOL_FLAG_NON_PAGED, info.DescriptorSize, SDB_POOL_TAG);
    if (ep->Preparsed == NULL) {
        status = STATUS_INSUFFICIENT_RESOURCES;
        goto Fail;
    }

    status = SdbSendIoctl(ep->Target, IOCTL_HID_GET_COLLECTION_DESCRIPTOR, NULL, 0,
                          ep->Preparsed, info.DescriptorSize, NULL);
    if (!NT_SUCCESS(status)) {
        goto Fail;
    }

    if (HidP_GetCaps(ep->Preparsed, &caps) != HIDP_STATUS_SUCCESS ||
        caps.UsagePage != SDB_USAGE_PAGE_MONITOR ||
        caps.Usage != SDB_USAGE_MONITOR_CONTROL ||
        caps.FeatureReportByteLength < 2) {
        status = STATUS_NOT_SUPPORTED;
        goto Fail;
    }

    count = 1;
    if (HidP_GetSpecificValueCaps(HidP_Feature, SDB_USAGE_PAGE_VESA_VIRTUAL, 0, SDB_USAGE_VESA_BRIGHTNESS,
                                  &brightness, &count, ep->Preparsed) != HIDP_STATUS_SUCCESS ||
        count == 0 ||
        brightness.LogicalMax <= brightness.LogicalMin ||
        brightness.LogicalMin < 0) {
        status = STATUS_NOT_SUPPORTED;
        goto Fail;
    }

    ep->ReportId = brightness.ReportID;
    ep->FeatureReportLength = caps.FeatureReportByteLength;
    ep->LogicalMin = brightness.LogicalMin;
    ep->LogicalMax = brightness.LogicalMax;

    if (SdbLuminanceScale(brightness.Units, brightness.UnitsExp, &scale)) {
        ep->MinMillinits = SdbScale(brightness.LogicalMin, scale);
        ep->MaxMillinits = SdbScale(brightness.LogicalMax, scale);
    }
    if (ep->MaxMillinits <= ep->MinMillinits) {
        ep->MinMillinits = SDB_NOMINAL_MIN_MILLINITS;
        ep->MaxMillinits = SDB_NOMINAL_MAX_MILLINITS;
    }

    count = 1;
    if (HidP_GetSpecificValueCaps(HidP_Feature, SDB_USAGE_PAGE_PID, 0, SDB_USAGE_PID_DURATION,
                                  &duration, &count, ep->Preparsed) == HIDP_STATUS_SUCCESS &&
        count > 0 &&
        duration.ReportID == ep->ReportId &&
        duration.LogicalMax > 0) {
        ep->HasDuration = TRUE;
        ep->DurationLogicalMax = duration.LogicalMax;
    }

    /* This is the monitor's control collection: reopen it for data access
     * and watch for the display going away. */
    WdfIoTargetClose(ep->Target);
    status = SdbOpenTarget(ep->Target, &ep->SymbolicLink, GENERIC_READ | GENERIC_WRITE, TRUE);
    if (!NT_SUCCESS(status)) {
        goto Fail;
    }

    status = SdbReadRawBrightness(ep, &raw);
    if (!NT_SUCCESS(status)) {
        goto Fail;
    }

    SDB_LOG("endpoint %wZ: report %u, logical %d..%d, %u..%u millinits, duration %d, current %d",
            &ep->SymbolicLink, ep->ReportId, ep->LogicalMin, ep->LogicalMax,
            ep->MinMillinits, ep->MaxMillinits, ep->HasDuration ? ep->DurationLogicalMax : 0, raw);

    *Endpoint = ep;
    return STATUS_SUCCESS;

Fail:
    SdbFreeEndpoint(ep);
    return status;
}

/* --------------------------------------------------------------------------
 * Binding
 * -------------------------------------------------------------------------- */

static BOOLEAN
SdbLinkClaimedLocked(
    _In_ PCUNICODE_STRING SymbolicLink
    )
{
    PLIST_ENTRY entry;

    for (entry = SdbGlobals.Devices.Flink; entry != &SdbGlobals.Devices; entry = entry->Flink) {
        PSDB_DEVICE_CONTEXT other = CONTAINING_RECORD(entry, SDB_DEVICE_CONTEXT, Link);

        if (other->Endpoint != NULL &&
            RtlEqualUnicodeString(&other->Endpoint->SymbolicLink, SymbolicLink, TRUE)) {
            return TRUE;
        }
    }
    return FALSE;
}

_Use_decl_annotations_
VOID
SdbUpdateInterfaceStateLocked(
    PSDB_DEVICE_CONTEXT Ctx
    )
{
    UNICODE_STRING reference;
    BOOLEAN enable = Ctx->Endpoint != NULL;

    /* On a panel with native backlight control the interface (same GUID and
     * reference string) belongs to monitor.sys: never touch its state. */
    if (!Ctx->InList || !Ctx->NativeChecked || Ctx->NativeBrightness) {
        return;
    }

    /* Always (re)apply: the framework enables every interface at start. */
    RtlInitUnicodeString(&reference, SDB_BRIGHTNESS_REFERENCE_STRING);
    WdfDeviceSetDeviceInterfaceState(Ctx->Device, &GUID_DEVINTERFACE_SDB_MONITOR_BRIGHTNESS, &reference, enable);

    if (enable != Ctx->InterfaceEnabled) {
        SDB_LOG("brightness interface %s", enable ? "enabled" : "disabled");
    }
    Ctx->InterfaceEnabled = enable;
}

_Use_decl_annotations_
VOID
SdbUnbindLocked(
    PSDB_DEVICE_CONTEXT Ctx
    )
{
    PSDB_ENDPOINT ep = Ctx->Endpoint;

    if (ep == NULL) {
        return;
    }

    SDB_LOG("releasing endpoint %wZ", &ep->SymbolicLink);
    Ctx->Endpoint = NULL;
    SdbFreeEndpoint(ep);
}

static VOID
SdbTryBindLocked(
    _In_ PSDB_DEVICE_CONTEXT Ctx,
    _In_ PZZWSTR Links
    )
{
    PWSTR link;

    for (link = Links; *link != UNICODE_NULL; link += wcslen(link) + 1) {
        UNICODE_STRING name;
        USHORT vendorId;
        USHORT productId;
        PSDB_ENDPOINT ep;

        if (!NT_SUCCESS(RtlUnicodeStringInit(&name, link))) {
            continue;
        }
        if (!SdbParseHexToken(&name, L"VID_", &vendorId) ||
            !SdbParseHexToken(&name, L"PID_", &productId)) {
            continue;
        }
        if (Ctx->RequiredVendorId != 0 ? vendorId != Ctx->RequiredVendorId : !SdbIsSupportedVendor(vendorId)) {
            continue;
        }
        if (SdbLinkClaimedLocked(&name)) {
            continue;
        }

        if (!NT_SUCCESS(SdbProbeEndpoint(Ctx, &name, vendorId, productId, &ep))) {
            continue;
        }

        Ctx->Endpoint = ep;

        /* Re-apply what Windows last asked for (e.g. after a replug). */
        if (Ctx->HaveTarget) {
            SdbHidSetMillinitsLocked(Ctx, Ctx->TargetMillinits, 0);
        }
        return;
    }
}

_Use_decl_annotations_
VOID
SdbRescanLocked(
    VOID
    )
{
    PZZWSTR links = NULL;
    PLIST_ENTRY entry;
    BOOLEAN needScan = FALSE;
    NTSTATUS status;

    for (entry = SdbGlobals.Devices.Flink; entry != &SdbGlobals.Devices; entry = entry->Flink) {
        PSDB_DEVICE_CONTEXT ctx = CONTAINING_RECORD(entry, SDB_DEVICE_CONTEXT, Link);

        /* Drop endpoints whose display went away (see SdbEvtTargetRemoveComplete).
         * A target closed for a pending query-remove may still come back. */
        if (ctx->Endpoint != NULL) {
            WDF_IO_TARGET_STATE state = WdfIoTargetGetState(ctx->Endpoint->Target);

            if (state != WdfIoTargetStarted && state != WdfIoTargetClosedForQueryRemove) {
                SdbUnbindLocked(ctx);
            }
        }
        if (ctx->Endpoint == NULL && ctx->NativeChecked && !ctx->NativeBrightness) {
            needScan = TRUE;
        }
    }

    if (needScan) {
        status = IoGetDeviceInterfaces(&GUID_DEVINTERFACE_HID, NULL, 0, &links);
        if (!NT_SUCCESS(status)) {
            SDB_LOG("IoGetDeviceInterfaces failed 0x%08X", status);
            links = NULL;
        }
    }

    for (entry = SdbGlobals.Devices.Flink; entry != &SdbGlobals.Devices; entry = entry->Flink) {
        PSDB_DEVICE_CONTEXT ctx = CONTAINING_RECORD(entry, SDB_DEVICE_CONTEXT, Link);

        if (ctx->Endpoint == NULL && links != NULL && ctx->NativeChecked && !ctx->NativeBrightness) {
            SdbTryBindLocked(ctx, links);
        }
        SdbUpdateInterfaceStateLocked(ctx);
    }

    if (links != NULL) {
        ExFreePool(links);
    }
}

/* The display was unplugged. This runs inside PnP notification delivery, so
 * it must not wait for SdbGlobals.Lock (a rescan holding it may be opening
 * another target, which registers for PnP notifications). Close the handle
 * so the removal can finish and let the rescan work item do the unbinding. */
VOID
SdbEvtTargetRemoveComplete(
    _In_ WDFIOTARGET IoTarget
    )
{
    WdfIoTargetClose(IoTarget);
    SdbRequestRescan();
}

/* --------------------------------------------------------------------------
 * Brightness I/O
 * -------------------------------------------------------------------------- */

_Use_decl_annotations_
NTSTATUS
SdbHidGetMillinitsLocked(
    PSDB_DEVICE_CONTEXT Ctx,
    PULONG Millinits
    )
{
    LONG raw;
    NTSTATUS status;

    *Millinits = 0;

    if (Ctx->Endpoint == NULL) {
        return STATUS_DEVICE_NOT_READY;
    }

    status = SdbReadRawBrightness(Ctx->Endpoint, &raw);
    if (NT_SUCCESS(status)) {
        *Millinits = SdbLogicalToMillinits(Ctx->Endpoint, raw);
    }
    return status;
}

_Use_decl_annotations_
NTSTATUS
SdbHidSetMillinitsLocked(
    PSDB_DEVICE_CONTEXT Ctx,
    ULONG Millinits,
    ULONG TransitionMs
    )
{
    PSDB_ENDPOINT ep = Ctx->Endpoint;
    PCHAR report;
    LONG raw;
    NTSTATUS status;

    if (ep == NULL) {
        return STATUS_DEVICE_NOT_READY;
    }

    report = ExAllocatePool2(POOL_FLAG_NON_PAGED, ep->FeatureReportLength, SDB_POOL_TAG);
    if (report == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    raw = SdbMillinitsToLogical(ep, Millinits);

    status = HidP_InitializeReportForID(HidP_Feature, ep->ReportId, ep->Preparsed, report, ep->FeatureReportLength);
    if (status == HIDP_STATUS_SUCCESS) {
        status = HidP_SetUsageValue(HidP_Feature, SDB_USAGE_PAGE_VESA_VIRTUAL, 0, SDB_USAGE_VESA_BRIGHTNESS,
                                    (ULONG)raw, ep->Preparsed, report, ep->FeatureReportLength);
    }
    if (status == HIDP_STATUS_SUCCESS && ep->HasDuration) {
        ULONG ms = TransitionMs > (ULONG)ep->DurationLogicalMax ? (ULONG)ep->DurationLogicalMax : TransitionMs;
        status = HidP_SetUsageValue(HidP_Feature, SDB_USAGE_PAGE_PID, 0, SDB_USAGE_PID_DURATION,
                                    ms, ep->Preparsed, report, ep->FeatureReportLength);
    }

    if (status == HIDP_STATUS_SUCCESS) {
        status = SdbSendIoctl(ep->Target, IOCTL_HID_SET_FEATURE, report, ep->FeatureReportLength, NULL, 0, NULL);
    } else {
        status = STATUS_UNSUCCESSFUL;
    }

    ExFreePoolWithTag(report, SDB_POOL_TAG);

    if (!NT_SUCCESS(status)) {
        SDB_LOG("set brightness %u millinits failed 0x%08X", Millinits, status);
    }
    return status;
}
