/*
 * StudioDisplayBrightness - driver entry, monitor filter device and the
 * brightness request handling. See sdb.h for the overall design.
 */
#include "sdb.h"

SDB_GLOBALS SdbGlobals;

/* Protects list membership for readers that cannot wait (PnP callback).
 * Writers of SdbGlobals.Devices hold both this lock and SdbGlobals.Lock. */
static WDFSPINLOCK SdbListLock;

DRIVER_INITIALIZE DriverEntry;
static EVT_WDF_DRIVER_DEVICE_ADD SdbEvtDeviceAdd;
static EVT_WDF_DRIVER_UNLOAD SdbEvtDriverUnload;
static EVT_WDF_DEVICE_SELF_MANAGED_IO_INIT SdbEvtSelfManagedIoInit;
static EVT_WDF_DEVICE_SELF_MANAGED_IO_CLEANUP SdbEvtSelfManagedIoCleanup;
static EVT_WDFDEVICE_WDM_IRP_PREPROCESS SdbEvtWdmPreprocess;
static EVT_WDF_WORKITEM SdbEvtRescanWorkItem;
static DRIVER_NOTIFICATION_CALLBACK_ROUTINE SdbHidInterfaceNotification;

#define SDB_LOG(fmt, ...) \
    DbgPrintEx(DPFLTR_IHVVIDEO_ID, DPFLTR_INFO_LEVEL, "StudioDisplayBrightness: " fmt "\n", __VA_ARGS__)

/* Sentinel: the request is not ours, pass it down to monitor.sys. */
#define SDB_STATUS_PASS_DOWN ((NTSTATUS)0xE0000001L)

/* --------------------------------------------------------------------------
 * Driver
 * -------------------------------------------------------------------------- */

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
    )
{
    WDF_DRIVER_CONFIG config;
    WDFDRIVER driver;
    NTSTATUS status;

    InitializeListHead(&SdbGlobals.Devices);

    WDF_DRIVER_CONFIG_INIT(&config, SdbEvtDeviceAdd);
    config.EvtDriverUnload = SdbEvtDriverUnload;

    status = WdfDriverCreate(DriverObject, RegistryPath, WDF_NO_OBJECT_ATTRIBUTES, &config, &driver);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    status = WdfWaitLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &SdbGlobals.Lock);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    status = WdfSpinLockCreate(WDF_NO_OBJECT_ATTRIBUTES, &SdbListLock);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    /* Existing HID interfaces are picked up by the rescan each monitor runs
     * when it starts; this notification covers displays plugged in later. */
    status = IoRegisterPlugPlayNotification(
        EventCategoryDeviceInterfaceChange,
        0,
        (PVOID)&GUID_DEVINTERFACE_HID,
        DriverObject,
        SdbHidInterfaceNotification,
        NULL,
        &SdbGlobals.HidNotificationEntry);
    if (!NT_SUCCESS(status)) {
        SDB_LOG("IoRegisterPlugPlayNotification failed 0x%08X", status);
        SdbGlobals.HidNotificationEntry = NULL;
    }

    return STATUS_SUCCESS;
}

static VOID
SdbEvtDriverUnload(
    _In_ WDFDRIVER Driver
    )
{
    UNREFERENCED_PARAMETER(Driver);

    if (SdbGlobals.HidNotificationEntry != NULL) {
        IoUnregisterPlugPlayNotificationEx(SdbGlobals.HidNotificationEntry);
        SdbGlobals.HidNotificationEntry = NULL;
    }
}

static NTSTATUS
SdbHidInterfaceNotification(
    _In_ PVOID NotificationStructure,
    _Inout_opt_ PVOID Context
    )
{
    PDEVICE_INTERFACE_CHANGE_NOTIFICATION notification = NotificationStructure;

    UNREFERENCED_PARAMETER(Context);

    /* Runs inside PnP notification delivery: only queue work, never wait
     * for SdbGlobals.Lock here. */
    if (IsEqualGUID(&notification->Event, &GUID_DEVICE_INTERFACE_ARRIVAL) ||
        IsEqualGUID(&notification->Event, &GUID_DEVICE_INTERFACE_REMOVAL)) {
        SdbRequestRescan();
    }

    return STATUS_SUCCESS;
}

/* Queue a rescan on any started monitor. Safe up to DISPATCH_LEVEL. */
VOID
SdbRequestRescan(
    VOID
    )
{
    PLIST_ENTRY entry;

    WdfSpinLockAcquire(SdbListLock);
    entry = SdbGlobals.Devices.Flink;
    if (entry != &SdbGlobals.Devices) {
        PSDB_DEVICE_CONTEXT ctx = CONTAINING_RECORD(entry, SDB_DEVICE_CONTEXT, Link);
        WdfWorkItemEnqueue(ctx->RescanWorkItem);
    }
    WdfSpinLockRelease(SdbListLock);
}

/* Asks monitor.sys below us whether it already drives this panel's
 * backlight. It answers the capability query only for panels whose GPU or
 * firmware supports brightness and fails it for every other monitor. */
static BOOLEAN
SdbQueryNativeBrightness(
    _In_ WDFDEVICE Device
    )
{
    PANEL_QUERY_BRIGHTNESS_CAPS caps;
    WDF_MEMORY_DESCRIPTOR input;
    WDF_MEMORY_DESCRIPTOR output;
    WDF_REQUEST_SEND_OPTIONS options;
    NTSTATUS status;

    RtlZeroMemory(&caps, sizeof(caps));
    caps.Version = BRIGHTNESS_INTERFACE_VERSION_3;
    WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&input, &caps, sizeof(caps));
    WDF_MEMORY_DESCRIPTOR_INIT_BUFFER(&output, &caps, sizeof(caps));
    WDF_REQUEST_SEND_OPTIONS_INIT(&options, 0);
    WDF_REQUEST_SEND_OPTIONS_SET_TIMEOUT(&options, WDF_REL_TIMEOUT_IN_MS(SDB_HID_TIMEOUT_MS));

    status = WdfIoTargetSendIoctlSynchronously(
        WdfDeviceGetIoTarget(Device), NULL, IOCTL_PANEL_QUERY_BRIGHTNESS_CAPS,
        &input, &output, &options, NULL);

    return NT_SUCCESS(status);
}

/* PASSIVE_LEVEL, SdbGlobals.Lock not held (the query goes down the stack). */
static VOID
SdbEnsureNativeChecked(
    _In_ PSDB_DEVICE_CONTEXT Ctx
    )
{
    BOOLEAN native;

    if (ReadBooleanAcquire(&Ctx->NativeChecked)) {
        return;
    }

    native = SdbQueryNativeBrightness(Ctx->Device);

    WdfWaitLockAcquire(SdbGlobals.Lock, NULL);
    if (!Ctx->NativeChecked) {
        Ctx->NativeBrightness = native;
        WriteBooleanRelease(&Ctx->NativeChecked, TRUE);
        if (native) {
            SDB_LOG("monitor has native backlight control; staying pass-through");
        }
    }
    WdfWaitLockRelease(SdbGlobals.Lock);
}

static VOID
SdbEvtRescanWorkItem(
    _In_ WDFWORKITEM WorkItem
    )
{
    SdbEnsureNativeChecked(SdbGetDeviceContext(WdfWorkItemGetParentObject(WorkItem)));

    WdfWaitLockAcquire(SdbGlobals.Lock, NULL);
    SdbRescanLocked();
    WdfWaitLockRelease(SdbGlobals.Lock);
}

/* --------------------------------------------------------------------------
 * Device add: attach only to monitors that can be backed by a HID endpoint.
 * -------------------------------------------------------------------------- */

typedef struct _SDB_VENDOR_MAP {
    WCHAR PnpId[4];
    USHORT UsbVendorId;
} SDB_VENDOR_MAP;

static const SDB_VENDOR_MAP SdbVendorMap[] = {
    { L"APP", 0x05AC },     /* Apple: Studio Display, Studio Display XDR, Pro Display XDR */
    { L"GSM", 0x043E },     /* LG: UltraFine 4K / 5K */
};

BOOLEAN
SdbIsSupportedVendor(
    _In_ USHORT UsbVendorId
    )
{
    ULONG i;

    for (i = 0; i < RTL_NUMBER_OF(SdbVendorMap); i++) {
        if (SdbVendorMap[i].UsbVendorId == UsbVendorId) {
            return TRUE;
        }
    }
    return FALSE;
}

static BOOLEAN
SdbShouldAttach(
    _In_ PWDFDEVICE_INIT DeviceInit,
    _Out_ PUSHORT RequiredVendorId
    )
{
    WDF_OBJECT_ATTRIBUTES attributes;
    WDFMEMORY memory = NULL;
    PCWSTR hardwareId;
    size_t length;
    UNICODE_STRING id;
    UNICODE_STRING prefix;
    UNICODE_STRING defaultMonitor;
    BOOLEAN attach = FALSE;
    ULONG i;

    *RequiredVendorId = 0;

    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    if (!NT_SUCCESS(WdfFdoInitAllocAndQueryProperty(
            DeviceInit, DevicePropertyHardwareID, NonPagedPoolNx, &attributes, &memory))) {
        return FALSE;
    }

    hardwareId = WdfMemoryGetBuffer(memory, &length);
    if (length < sizeof(WCHAR) * 12 ||
        !NT_SUCCESS(RtlUnicodeStringInitEx(&id, hardwareId, STRSAFE_IGNORE_NULLS))) {
        goto Exit;
    }

    /* Hardware IDs are "MONITOR\<PNPID><product>" or "MONITOR\Default_Monitor". */
    RtlInitUnicodeString(&prefix, L"MONITOR\\");
    RtlInitUnicodeString(&defaultMonitor, L"MONITOR\\Default_Monitor");

    if (RtlEqualUnicodeString(&id, &defaultMonitor, TRUE)) {
        attach = TRUE;
        goto Exit;
    }

    if (!RtlPrefixUnicodeString(&prefix, &id, TRUE) ||
        id.Length < prefix.Length + 3 * sizeof(WCHAR)) {
        goto Exit;
    }

    for (i = 0; i < RTL_NUMBER_OF(SdbVendorMap); i++) {
        UNICODE_STRING pnpId;
        UNICODE_STRING candidate;

        RtlInitUnicodeString(&pnpId, SdbVendorMap[i].PnpId);
        candidate.Buffer = id.Buffer + prefix.Length / sizeof(WCHAR);
        candidate.Length = pnpId.Length;
        candidate.MaximumLength = pnpId.Length;

        if (RtlEqualUnicodeString(&pnpId, &candidate, TRUE)) {
            *RequiredVendorId = SdbVendorMap[i].UsbVendorId;
            attach = TRUE;
            break;
        }
    }

Exit:
    WdfObjectDelete(memory);
    return attach;
}

static NTSTATUS
SdbEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit
    )
{
    static UCHAR majors[] = { IRP_MJ_CREATE, IRP_MJ_CLEANUP, IRP_MJ_CLOSE, IRP_MJ_DEVICE_CONTROL };
    WDF_PNPPOWER_EVENT_CALLBACKS pnpPower;
    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_WORKITEM_CONFIG workItemConfig;
    UNICODE_STRING reference;
    PSDB_DEVICE_CONTEXT ctx;
    USHORT vendorId;
    WDFDEVICE device;
    NTSTATUS status;
    ULONG i;

    UNREFERENCED_PARAMETER(Driver);

    /* Class filter: never fail AddDevice, or the monitor would not start. */
    WdfFdoInitSetFilter(DeviceInit);

    if (!SdbShouldAttach(DeviceInit, &vendorId)) {
        return STATUS_SUCCESS;
    }

    for (i = 0; i < RTL_NUMBER_OF(majors); i++) {
        status = WdfDeviceInitAssignWdmIrpPreprocessCallback(
            DeviceInit, SdbEvtWdmPreprocess, majors[i], NULL, 0);
        if (!NT_SUCCESS(status)) {
            SDB_LOG("preprocess registration failed 0x%08X", status);
            return STATUS_SUCCESS;
        }
    }

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpPower);
    pnpPower.EvtDeviceSelfManagedIoInit = SdbEvtSelfManagedIoInit;
    pnpPower.EvtDeviceSelfManagedIoCleanup = SdbEvtSelfManagedIoCleanup;
    WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnpPower);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, SDB_DEVICE_CONTEXT);
    status = WdfDeviceCreate(&DeviceInit, &attributes, &device);
    if (!NT_SUCCESS(status)) {
        SDB_LOG("WdfDeviceCreate failed 0x%08X", status);
        return STATUS_SUCCESS;
    }

    ctx = SdbGetDeviceContext(device);
    ctx->Device = device;
    ctx->RequiredVendorId = vendorId;
    ctx->SmoothEnabled = TRUE;
    InitializeListHead(&ctx->Link);

    WDF_WORKITEM_CONFIG_INIT(&workItemConfig, SdbEvtRescanWorkItem);
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = device;
    status = WdfWorkItemCreate(&workItemConfig, &attributes, &ctx->RescanWorkItem);
    if (!NT_SUCCESS(status)) {
        SDB_LOG("WdfWorkItemCreate failed 0x%08X", status);
        ctx->RescanWorkItem = NULL;
        return STATUS_SUCCESS;
    }

    RtlInitUnicodeString(&reference, SDB_BRIGHTNESS_REFERENCE_STRING);
    status = WdfDeviceCreateDeviceInterface(device, &GUID_DEVINTERFACE_SDB_MONITOR_BRIGHTNESS, &reference);
    if (!NT_SUCCESS(status)) {
        /* Without the interface nobody can find us: stay a pass-through. */
        SDB_LOG("WdfDeviceCreateDeviceInterface failed 0x%08X", status);
        return STATUS_SUCCESS;
    }
    ctx->HasInterface = TRUE;

    SDB_LOG("attached to monitor (required USB vendor 0x%04X)", vendorId);
    return STATUS_SUCCESS;
}

static NTSTATUS
SdbEvtSelfManagedIoInit(
    _In_ WDFDEVICE Device
    )
{
    PSDB_DEVICE_CONTEXT ctx = SdbGetDeviceContext(Device);

    if (!ctx->HasInterface) {
        return STATUS_SUCCESS;
    }

    WdfWaitLockAcquire(SdbGlobals.Lock, NULL);
    WdfSpinLockAcquire(SdbListLock);
    InsertTailList(&SdbGlobals.Devices, &ctx->Link);
    ctx->InList = TRUE;
    WdfSpinLockRelease(SdbListLock);
    WdfWaitLockRelease(SdbGlobals.Lock);

    /* Run the first bind asynchronously so it happens after the framework
     * has finished starting the device and enabled its interfaces. */
    WdfWorkItemEnqueue(ctx->RescanWorkItem);
    return STATUS_SUCCESS;
}

static VOID
SdbEvtSelfManagedIoCleanup(
    _In_ WDFDEVICE Device
    )
{
    PSDB_DEVICE_CONTEXT ctx = SdbGetDeviceContext(Device);
    BOOLEAN released = FALSE;

    WdfWaitLockAcquire(SdbGlobals.Lock, NULL);
    if (ctx->InList) {
        WdfSpinLockAcquire(SdbListLock);
        RemoveEntryList(&ctx->Link);
        InitializeListHead(&ctx->Link);
        ctx->InList = FALSE;
        WdfSpinLockRelease(SdbListLock);
    }
    if (ctx->Endpoint != NULL) {
        SdbUnbindLocked(ctx);
        released = TRUE;
    }
    WdfWaitLockRelease(SdbGlobals.Lock);

    if (ctx->RescanWorkItem != NULL) {
        WdfWorkItemFlush(ctx->RescanWorkItem);
    }

    /* Another monitor may be able to use the endpoint we just released. */
    if (released) {
        SdbRequestRescan();
    }
}

/* --------------------------------------------------------------------------
 * Brightness operations (SdbGlobals.Lock held)
 * -------------------------------------------------------------------------- */

static NTSTATUS
SdbSetBrightnessLocked(
    _In_ PSDB_DEVICE_CONTEXT Ctx,
    _In_ const PANEL_SET_BRIGHTNESS* Request,
    _In_ ULONG RequestLength
    )
{
    PSDB_ENDPOINT ep = Ctx->Endpoint;
    ULONG millinits;
    ULONG transitionMs = 0;
    NTSTATUS status;

    if (ep == NULL) {
        return STATUS_DEVICE_NOT_READY;
    }

    switch (Request->Version) {
    case BRIGHTNESS_INTERFACE_VERSION_1:
    case BRIGHTNESS_INTERFACE_VERSION_2:
        if (Request->Level > 100) {
            return STATUS_INVALID_PARAMETER;
        }
        millinits = SdbPercentToMillinits(ep, Request->Level);
        break;

    case BRIGHTNESS_INTERFACE_VERSION_3:
        if (RequestLength < FIELD_OFFSET(PANEL_SET_BRIGHTNESS, SensorData)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        millinits = Request->Millinits;
        if (Ctx->SmoothEnabled) {
            transitionMs = Request->TransitionTimeInMs;
        }
        break;

    default:
        return STATUS_INVALID_PARAMETER;
    }

    if (millinits < ep->MinMillinits) {
        millinits = ep->MinMillinits;
    } else if (millinits > ep->MaxMillinits) {
        millinits = ep->MaxMillinits;
    }

    status = SdbHidSetMillinitsLocked(Ctx, millinits, transitionMs);
    if (NT_SUCCESS(status)) {
        Ctx->TargetMillinits = millinits;
        Ctx->HaveTarget = TRUE;
    }
    return status;
}

static NTSTATUS
SdbGetBrightnessLocked(
    _In_ PSDB_DEVICE_CONTEXT Ctx,
    _Out_ PANEL_GET_BRIGHTNESS* Result
    )
{
    ULONG current;
    NTSTATUS status;

    RtlZeroMemory(Result, sizeof(*Result));

    if (Ctx->Endpoint == NULL) {
        return STATUS_DEVICE_NOT_READY;
    }

    status = SdbHidGetMillinitsLocked(Ctx, &current);
    if (!NT_SUCCESS(status)) {
        if (!Ctx->HaveTarget) {
            return status;
        }
        current = Ctx->TargetMillinits;
    }

    Result->Version = BRIGHTNESS_INTERFACE_VERSION_3;
    Result->CurrentInMillinits = current;
    Result->TargetInMillinits = Ctx->HaveTarget ? Ctx->TargetMillinits : current;
    return STATUS_SUCCESS;
}

/* --------------------------------------------------------------------------
 * IOCTL handling
 * -------------------------------------------------------------------------- */

static NTSTATUS
SdbHandleIoctl(
    _In_ PSDB_DEVICE_CONTEXT Ctx,
    _In_ ULONG Code,
    _Inout_updates_bytes_opt_(max(InLength, OutLength)) PVOID Buffer,
    _In_ ULONG InLength,
    _In_ ULONG OutLength,
    _Out_ PULONG_PTR Information
    )
{
    NTSTATUS status;
    PSDB_ENDPOINT ep;

    *Information = 0;

    /* Panel IOCTLs are only claimed while a HID endpoint backs this monitor;
     * otherwise monitor.sys answers them as it always has. */
    if (DEVICE_TYPE_FROM_CTL_CODE(Code) == FILE_DEVICE_VIDEO &&
        Code >= IOCTL_PANEL_QUERY_BRIGHTNESS_CAPS && Code <= IOCTL_PANEL_GET_MANUFACTURING_MODE &&
        (Ctx->Endpoint == NULL || Code == IOCTL_PANEL_GET_MANUFACTURING_MODE)) {
        return SDB_STATUS_PASS_DOWN;
    }

    ep = Ctx->Endpoint;

    switch (Code) {
    case IOCTL_SDB_MONITOR_SET_BRIGHTNESS:
    case IOCTL_PANEL_SET_BRIGHTNESS:
        if (Buffer == NULL || InLength < RTL_SIZEOF_THROUGH_FIELD(PANEL_SET_BRIGHTNESS, Level)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        return SdbSetBrightnessLocked(Ctx, Buffer, InLength);

    case IOCTL_SDB_MONITOR_GET_BRIGHTNESS:
    case IOCTL_PANEL_GET_BRIGHTNESS: {
        PANEL_GET_BRIGHTNESS result;

        if (Buffer == NULL || OutLength < sizeof(PANEL_GET_BRIGHTNESS)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        status = SdbGetBrightnessLocked(Ctx, &result);
        if (!NT_SUCCESS(status)) {
            return status;
        }
        if (Code == IOCTL_SDB_MONITOR_GET_BRIGHTNESS && OutLength >= sizeof(SDB_GET_BRIGHTNESS)) {
            PSDB_GET_BRIGHTNESS out = Buffer;
            out->Panel = result;
            out->Reserved = 0;
            *Information = sizeof(SDB_GET_BRIGHTNESS);
        } else {
            *(PANEL_GET_BRIGHTNESS*)Buffer = result;
            *Information = sizeof(PANEL_GET_BRIGHTNESS);
        }
        return STATUS_SUCCESS;
    }

    case IOCTL_SDB_MONITOR_SET_TRANSITION_TIMES:
        if (Buffer == NULL || InLength < sizeof(SDB_TRANSITION_TIMES)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        Ctx->TransitionTimes = *(SDB_TRANSITION_TIMES*)Buffer;
        return STATUS_SUCCESS;

    case IOCTL_SDB_MONITOR_SET_POLICY_BRIGHTNESS: {
        const SDB_POLICY_BRIGHTNESS* policy = Buffer;
        PANEL_SET_BRIGHTNESS request;

        if (Buffer == NULL || InLength < sizeof(SDB_POLICY_BRIGHTNESS)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        if (policy->AcPercent > 100 || policy->DcPercent > 100) {
            return STATUS_INVALID_PARAMETER;
        }
        /* A monitor powered from the wall: always the AC policy value. */
        RtlZeroMemory(&request, sizeof(request));
        request.Version = BRIGHTNESS_INTERFACE_VERSION_1;
        request.Level = policy->AcPercent;
        return SdbSetBrightnessLocked(Ctx, &request, sizeof(request));
    }

    case IOCTL_PANEL_QUERY_BRIGHTNESS_CAPS: {
        PPANEL_QUERY_BRIGHTNESS_CAPS caps = Buffer;

        if (Buffer == NULL || OutLength < sizeof(PANEL_QUERY_BRIGHTNESS_CAPS)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        RtlZeroMemory(caps, sizeof(*caps));
        caps->Version = BRIGHTNESS_INTERFACE_VERSION_3;
        caps->Smooth = 1;
        caps->NitsCalibrated = ep->MinMillinits != SDB_NOMINAL_MIN_MILLINITS ||
                               ep->MaxMillinits != SDB_NOMINAL_MAX_MILLINITS;
        *Information = sizeof(PANEL_QUERY_BRIGHTNESS_CAPS);
        return STATUS_SUCCESS;
    }

    case IOCTL_PANEL_QUERY_BRIGHTNESS_RANGES: {
        PPANEL_QUERY_BRIGHTNESS_RANGES ranges = Buffer;
        BRIGHTNESS_INTERFACE_VERSION requested = BRIGHTNESS_INTERFACE_VERSION_3;
        ULONG step;
        LONG span;

        if (Buffer == NULL || OutLength < sizeof(PANEL_QUERY_BRIGHTNESS_RANGES)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        if (InLength >= sizeof(ULONG)) {
            requested = ranges->Version;
        }
        RtlZeroMemory(ranges, sizeof(*ranges));

        if (requested == BRIGHTNESS_INTERFACE_VERSION_1 || requested == BRIGHTNESS_INTERFACE_VERSION_2) {
            UCHAR level;

            ranges->Version = requested;
            ranges->BrightnessLevel.Count = 101;
            for (level = 0; level <= 100; level++) {
                ranges->BrightnessLevel.Level[level] = level;
            }
        } else {
            span = ep->LogicalMax - ep->LogicalMin;
            step = span > 0 ? (ep->MaxMillinits - ep->MinMillinits) / (ULONG)span : 1;
            ranges->Version = BRIGHTNESS_INTERFACE_VERSION_3;
            ranges->NitRanges.NormalRangeCount = 1;
            ranges->NitRanges.RangeCount = 1;
            ranges->NitRanges.PreferredMaximumBrightness = ep->MaxMillinits;
            ranges->NitRanges.SupportedRanges[0].MinLevelInMillinit = ep->MinMillinits;
            ranges->NitRanges.SupportedRanges[0].MaxLevelInMillinit = ep->MaxMillinits;
            ranges->NitRanges.SupportedRanges[0].StepSizeInMillinit = step ? step : 1;
        }
        *Information = sizeof(PANEL_QUERY_BRIGHTNESS_RANGES);
        return STATUS_SUCCESS;
    }

    case IOCTL_PANEL_SET_BRIGHTNESS_STATE:
        if (Buffer == NULL || InLength < sizeof(PANEL_SET_BRIGHTNESS_STATE)) {
            return STATUS_BUFFER_TOO_SMALL;
        }
        Ctx->SmoothEnabled = ((PANEL_SET_BRIGHTNESS_STATE*)Buffer)->Smooth != 0;
        return STATUS_SUCCESS;

    case IOCTL_PANEL_SET_BACKLIGHT_OPTIMIZATION:
        /* Content-adaptive backlight control does not apply to this panel. */
        return STATUS_SUCCESS;

    case IOCTL_PANEL_GET_BACKLIGHT_REDUCTION:
        return STATUS_NOT_SUPPORTED;

    default:
        return SDB_STATUS_PASS_DOWN;
    }
}

static BOOLEAN
SdbIsBrightnessFile(
    _In_opt_ PFILE_OBJECT FileObject
    )
{
    UNICODE_STRING name;

    if (FileObject == NULL || FileObject->FileName.Length == 0) {
        return FALSE;
    }

    RtlInitUnicodeString(&name, L"\\" SDB_BRIGHTNESS_REFERENCE_STRING);
    return RtlEqualUnicodeString(&FileObject->FileName, &name, TRUE);
}

static BOOLEAN
SdbIsPrivateIoctl(
    _In_ ULONG Code
    )
{
    return Code == IOCTL_SDB_MONITOR_SET_BRIGHTNESS ||
           Code == IOCTL_SDB_MONITOR_GET_BRIGHTNESS ||
           Code == IOCTL_SDB_MONITOR_SET_TRANSITION_TIMES ||
           Code == IOCTL_SDB_MONITOR_SET_POLICY_BRIGHTNESS;
}

static NTSTATUS
SdbCompleteIrp(
    _Inout_ PIRP Irp,
    _In_ NTSTATUS Status,
    _In_ ULONG_PTR Information
    )
{
    Irp->IoStatus.Status = Status;
    Irp->IoStatus.Information = Information;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return Status;
}

static NTSTATUS
SdbEvtWdmPreprocess(
    _In_ WDFDEVICE Device,
    _Inout_ PIRP Irp
    )
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    PSDB_DEVICE_CONTEXT ctx = SdbGetDeviceContext(Device);
    BOOLEAN ours = FALSE;

    if (ctx->HasInterface && SdbIsBrightnessFile(stack->FileObject)) {
        /* Decide before the first handle is ours: on a panel monitor.sys
         * already controls, its own brightness interface must keep working. */
        if (stack->MajorFunction == IRP_MJ_CREATE && KeGetCurrentIrql() == PASSIVE_LEVEL) {
            SdbEnsureNativeChecked(ctx);
        }
        ours = ReadBooleanAcquire(&ctx->NativeChecked) && !ctx->NativeBrightness;
    }

    switch (stack->MajorFunction) {
    case IRP_MJ_CREATE:
    case IRP_MJ_CLEANUP:
    case IRP_MJ_CLOSE:
        /* <monitor interface>\brightness handles belong to this filter;
         * monitor.sys never sees them. */
        if (ours) {
            return SdbCompleteIrp(Irp, STATUS_SUCCESS, 0);
        }
        break;

    case IRP_MJ_DEVICE_CONTROL: {
        ULONG code = stack->Parameters.DeviceIoControl.IoControlCode;
        BOOLEAN kernelCaller = Irp->RequestorMode == KernelMode;
        /* Only monitors confirmed to lack native backlight control are ours. */
        BOOLEAN claimable = ctx->HasInterface &&
                            ReadBooleanAcquire(&ctx->NativeChecked) &&
                            !ctx->NativeBrightness;
        ULONG_PTR information = 0;
        NTSTATUS status;

        if (SdbIsPrivateIoctl(code)) {
            /* Same rule as monitor.sys: user mode must use the brightness
             * handle. Anything else goes down for monitor.sys to handle. */
            if (!ours && !(kernelCaller && claimable)) {
                break;
            }
        } else if (DEVICE_TYPE_FROM_CTL_CODE(code) != FILE_DEVICE_VIDEO ||
                   code < IOCTL_PANEL_QUERY_BRIGHTNESS_CAPS ||
                   code > IOCTL_PANEL_GET_MANUFACTURING_MODE ||
                   !kernelCaller || !claimable) {
            /* Panel IOCTLs are kernel-only, as in monitor.sys. */
            break;
        }

        if (KeGetCurrentIrql() != PASSIVE_LEVEL) {
            if (ours) {
                return SdbCompleteIrp(Irp, STATUS_INVALID_DEVICE_STATE, 0);
            }
            break;
        }

        WdfWaitLockAcquire(SdbGlobals.Lock, NULL);
        status = SdbHandleIoctl(
            ctx,
            code,
            Irp->AssociatedIrp.SystemBuffer,
            stack->Parameters.DeviceIoControl.InputBufferLength,
            stack->Parameters.DeviceIoControl.OutputBufferLength,
            &information);
        WdfWaitLockRelease(SdbGlobals.Lock);

        if (status == SDB_STATUS_PASS_DOWN) {
            if (ours) {
                return SdbCompleteIrp(Irp, STATUS_INVALID_DEVICE_REQUEST, 0);
            }
            break;
        }

        return SdbCompleteIrp(Irp, status, information);
    }

    default:
        break;
    }

    IoSkipCurrentIrpStackLocation(Irp);
    return WdfDeviceWdmDispatchPreprocessedIrp(Device, Irp);
}
