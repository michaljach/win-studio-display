/*
 * StudioDisplayBrightness - KMDF upper filter for the Monitor device class.
 *
 * Exposes the brightness of USB Monitor Control Class displays (Apple Studio
 * Display, Studio Display XDR, LG UltraFine, ...) to the Windows brightness
 * stack, so the Settings / Quick Settings slider, brightness keys and power
 * policies drive the monitor directly.
 *
 * How Windows finds a brightness-capable display (Windows 11, verified by
 * inspecting monitor.sys and Microsoft.Graphics.Display.DisplayEnhancementService.dll):
 *
 *   - monitor.sys registers device interface {DB524086-...} with reference
 *     string "brightness" on the monitor devnode when the panel supports
 *     nits-based (BRIGHTNESS_INTERFACE_VERSION_3) brightness.
 *   - The arrival of that interface trigger-starts DisplayEnhancementService,
 *     which opens <interface>\brightness and drives it with the private
 *     IOCTL_SDB_MONITOR_* codes below.
 *   - dxgkrnl / win32kbase additionally query the public IOCTL_PANEL_* codes
 *     (ntddvdeo.h) on the monitor stack.
 *
 * This filter sits above monitor.sys, registers the same interface, and
 * services those requests by reading / writing the monitor's HID feature
 * report instead of a GPU backlight.
 */
#pragma once

#include <ntddk.h>
// KMDF places its const context type info in ".data"; clang then emits a
// second, read-only ".data" section. Keep it with the other constants.
#define WDF_TYPE_DEFAULT_SECTION_NAME ".rdata"
#include <wdf.h>
#include <initguid.h>
#include <wdmguid.h>
#include <ntddvdeo.h>
#include <hidclass.h>
#include <hidusage.h>
#include <hidpi.h>
#include <ntstrsafe.h>

#define SDB_POOL_TAG 'bdSS'

/* --------------------------------------------------------------------------
 * Private DisplayEnhancementService <-> monitor contract.
 * -------------------------------------------------------------------------- */

/* {DB524086-BA90-4E1E-BE42-894E94ECF289} - monitor supports nits brightness */
DEFINE_GUID(GUID_DEVINTERFACE_SDB_MONITOR_BRIGHTNESS,
    0xdb524086, 0xba90, 0x4e1e, 0xbe, 0x42, 0x89, 0x4e, 0x94, 0xec, 0xf2, 0x89);

#define SDB_BRIGHTNESS_REFERENCE_STRING L"brightness"

#define IOCTL_SDB_MONITOR_SET_BRIGHTNESS \
    CTL_CODE(FILE_DEVICE_VIDEO, 0x001, METHOD_BUFFERED, FILE_READ_ACCESS)   /* 0x234004 */
#define IOCTL_SDB_MONITOR_GET_BRIGHTNESS \
    CTL_CODE(FILE_DEVICE_VIDEO, 0x002, METHOD_BUFFERED, FILE_READ_ACCESS)   /* 0x234008 */
#define IOCTL_SDB_MONITOR_SET_TRANSITION_TIMES \
    CTL_CODE(FILE_DEVICE_VIDEO, 0x003, METHOD_BUFFERED, FILE_READ_ACCESS)   /* 0x23400C */
#define IOCTL_SDB_MONITOR_SET_POLICY_BRIGHTNESS \
    CTL_CODE(FILE_DEVICE_VIDEO, 0x004, METHOD_BUFFERED, FILE_READ_ACCESS)   /* 0x234010 */

/* Input of IOCTL_SDB_MONITOR_SET_BRIGHTNESS (0x24 bytes). */
typedef struct _SDB_SET_BRIGHTNESS {
    PANEL_SET_BRIGHTNESS Panel;
    ULONG Reserved;
} SDB_SET_BRIGHTNESS, *PSDB_SET_BRIGHTNESS;

/* Output of IOCTL_SDB_MONITOR_GET_BRIGHTNESS (0x10 bytes). */
typedef struct _SDB_GET_BRIGHTNESS {
    PANEL_GET_BRIGHTNESS Panel;
    ULONG Reserved;
} SDB_GET_BRIGHTNESS, *PSDB_GET_BRIGHTNESS;

/* Input of IOCTL_SDB_MONITOR_SET_TRANSITION_TIMES (dim / undim, ms). */
typedef struct _SDB_TRANSITION_TIMES {
    ULONG DimMs;
    ULONG UndimMs;
} SDB_TRANSITION_TIMES;

/* Input of IOCTL_SDB_MONITOR_SET_POLICY_BRIGHTNESS (power-policy percent). */
typedef struct _SDB_POLICY_BRIGHTNESS {
    UCHAR AcPercent;
    UCHAR DcPercent;
} SDB_POLICY_BRIGHTNESS;

C_ASSERT(sizeof(SDB_SET_BRIGHTNESS) == 0x24);
C_ASSERT(sizeof(SDB_GET_BRIGHTNESS) == 0x10);
C_ASSERT(sizeof(SDB_TRANSITION_TIMES) == 8);
C_ASSERT(sizeof(SDB_POLICY_BRIGHTNESS) == 2);

/* --------------------------------------------------------------------------
 * HID Monitor Control Class usages.
 * -------------------------------------------------------------------------- */

#define SDB_USAGE_PAGE_MONITOR          0x80
#define SDB_USAGE_MONITOR_CONTROL       0x01
#define SDB_USAGE_PAGE_VESA_VIRTUAL     0x82
#define SDB_USAGE_VESA_BRIGHTNESS       0x10
#define SDB_USAGE_PAGE_PID              0x0F
#define SDB_USAGE_PID_DURATION          0x50

/* Nominal range used when the brightness usage carries no luminance unit. */
#define SDB_NOMINAL_MIN_MILLINITS       5000
#define SDB_NOMINAL_MAX_MILLINITS       500000

#define SDB_HID_TIMEOUT_MS              2000

/* --------------------------------------------------------------------------
 * Per-monitor filter context.
 * -------------------------------------------------------------------------- */

typedef struct _SDB_ENDPOINT {
    WDFIOTARGET Target;
    UNICODE_STRING SymbolicLink;        /* owned, pool allocated */
    PHIDP_PREPARSED_DATA Preparsed;     /* owned, pool allocated */
    USHORT VendorId;
    USHORT ProductId;
    UCHAR ReportId;
    USHORT FeatureReportLength;
    LONG LogicalMin;
    LONG LogicalMax;
    ULONG MinMillinits;
    ULONG MaxMillinits;
    BOOLEAN HasDuration;
    LONG DurationLogicalMax;
} SDB_ENDPOINT, *PSDB_ENDPOINT;

typedef struct _SDB_DEVICE_CONTEXT {
    WDFDEVICE Device;
    LIST_ENTRY Link;                    /* SdbGlobals.Devices */
    BOOLEAN InList;
    BOOLEAN HasInterface;
    BOOLEAN InterfaceEnabled;
    WDFWORKITEM RescanWorkItem;

    /* 0 = any supported vendor (EDID-less "Default_Monitor"). */
    USHORT RequiredVendorId;

    /* Set once, under SdbGlobals.Lock: monitor.sys already controls this
     * panel's backlight (e.g. a Boot Camp MacBook's built-in display). Such
     * monitors are left entirely to monitor.sys. */
    BOOLEAN NativeChecked;
    BOOLEAN NativeBrightness;

    /* Bound HID endpoint, protected by SdbGlobals.Lock. */
    PSDB_ENDPOINT Endpoint;

    /* Last requested state, protected by SdbGlobals.Lock. */
    ULONG TargetMillinits;
    BOOLEAN HaveTarget;
    SDB_TRANSITION_TIMES TransitionTimes;
    BOOLEAN SmoothEnabled;
} SDB_DEVICE_CONTEXT, *PSDB_DEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(SDB_DEVICE_CONTEXT, SdbGetDeviceContext)

typedef struct _SDB_GLOBALS {
    WDFWAITLOCK Lock;                   /* devices, bindings, HID I/O */
    LIST_ENTRY Devices;
    PVOID HidNotificationEntry;
} SDB_GLOBALS;

extern SDB_GLOBALS SdbGlobals;

/* driver.c */
VOID SdbRequestRescan(VOID);
BOOLEAN SdbIsSupportedVendor(_In_ USHORT UsbVendorId);

/* hid.c */
_IRQL_requires_(PASSIVE_LEVEL)
VOID SdbRescanLocked(VOID);

_IRQL_requires_(PASSIVE_LEVEL)
VOID SdbUnbindLocked(_In_ PSDB_DEVICE_CONTEXT Ctx);

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS SdbHidGetMillinitsLocked(_In_ PSDB_DEVICE_CONTEXT Ctx, _Out_ PULONG Millinits);

_IRQL_requires_(PASSIVE_LEVEL)
NTSTATUS SdbHidSetMillinitsLocked(_In_ PSDB_DEVICE_CONTEXT Ctx, _In_ ULONG Millinits, _In_ ULONG TransitionMs);

ULONG SdbPercentToMillinits(_In_ PSDB_ENDPOINT Ep, _In_ ULONG Percent);

_IRQL_requires_(PASSIVE_LEVEL)
VOID SdbUpdateInterfaceStateLocked(_In_ PSDB_DEVICE_CONTEXT Ctx);

EVT_WDF_IO_TARGET_REMOVE_COMPLETE SdbEvtTargetRemoveComplete;
