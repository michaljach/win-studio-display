# StudioDisplayBrightness driver

A kernel-mode filter driver that makes the Apple Studio Display (and other USB
Monitor Control Class displays) a brightness-capable display to Windows. Once
it is installed, Windows' own controls work with no app running:

- the brightness slider in **Settings > System > Display**
- the brightness slider in **Quick Settings** (Win+A)
- keyboard brightness keys and the power-plan brightness settings

Supported: Windows 10 version 2004 or later and Windows 11, x64 and ARM64.

## Installing (users)

1. Download `StudioDisplayBrightness-<version>.zip` from the releases page and
   unzip it.
2. Double-click `install.cmd` and accept the administrator prompt.

Release builds are signed by Microsoft, so they install on a normal PC with
Secure Boot on; nothing else needs changing. To remove the driver, double-click
`uninstall.cmd`.

## How it works

Windows 11 decides whether a display has adjustable brightness by looking for a
device interface on the monitor's device node. `monitor.sys` registers
`{DB524086-BA90-4E1E-BE42-894E94ECF289}` (reference string `brightness`) only
for laptop panels whose GPU driver supports nits-based backlight control. The
arrival of that interface starts the **Display Enhancement Service**, which
then reads and sets brightness through private IOCTLs on it.

The package is an **extension INF** that adds this driver as an upper filter
above `monitor.sys` on every monitor (compatible ID `*PNP09FF`). The driver:

1. Stays a pure pass-through unless the monitor is Apple (`MONITOR\APP*`), LG
   (`MONITOR\GSM*`) or EDID-less (`MONITOR\Default_Monitor`).
2. Asks `monitor.sys` whether it already controls the panel's backlight (a
   Boot Camp MacBook's built-in screen, for example). If so, the driver leaves
   that monitor alone.
3. Finds the display's HID *Monitor Control* collection (usage page `0x80`)
   and reads the brightness control's range and unit from the report
   descriptor. On the Studio Display, brightness is in 0.01 nit steps
   (400–60000 = 4–600 nits), and the same report has a transition-time field
   that the display uses for smooth ramps.
4. Registers the brightness interface and enables it only while that HID
   endpoint is present, so the slider appears when the display is plugged in
   and goes away when it's unplugged.
5. Answers the Display Enhancement Service's requests (`0x234004` set,
   `0x234008` get, `0x23400C` dim timing, `0x234010` power-policy percent) and
   kernel `IOCTL_PANEL_*` queries by sending HID feature reports.

The private IOCTL contract was read from `monitor.sys` and
`Microsoft.Graphics.Display.DisplayEnhancementService.dll` on Windows 11 build
26300. It is an internal Windows interface, so every Windows feature update
should be checked before it ships (see the test checklist below).

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/` | Driver source (`driver.c`, `hid.c`, `sdb.h`, version resource) |
| `package/StudioDisplayBrightness.inf` | Extension INF template (DriverVer and provider are stamped at build time) |
| `build.ps1` | Builds, validates (InfVerif `/h`), catalogs and optionally test-signs the package |
| `package-submission.ps1` | Creates the EV-signed CAB for Partner Center |
| `package-release.ps1` | Verifies the Microsoft-signed download and creates the user zip |
| `install.ps1` / `install.cmd` | Installs a package (`pnputil`), with rollback |
| `uninstall.ps1` / `uninstall.cmd` | Removes it |
| `test-driver.ps1` | Talks to the driver the way Windows does |

## Building

No Visual Studio needed. From a normal PowerShell:

```powershell
.\driver\build.ps1                                   # test-signed dev build
.\driver\build.ps1 -Version 1.2.0.0 -Company "Your Company" -Sign None   # for submission
```

The first run downloads the Windows Driver Kit and SDK NuGet packages and a
portable LLVM (about 2 GB) into `%LOCALAPPDATA%\wsd-toolchain`. Every build:

- compiles x64 and ARM64 at `/W4 /WX` with `/GS` stack cookies and Control Flow Guard
- embeds a version resource
- checks HVCI (Memory Integrity) compatibility: NX, no writable+executable
  sections, CFG, and a `/GS` cookie in the load config
- validates the INF against the WHQL signature rules (`InfVerif /h`)
- generates the catalog with `Inf2Cat` (Windows 10 2004 through 24H2+,
  x64 and ARM64)

The package lands in `driver\dist\package\StudioDisplayBrightness\`. GitHub
Actions (`.github/workflows/driver.yml`) builds the same unsigned package and
submission CAB on every push.

## Releasing a Microsoft-signed driver (maintainers)

Windows only loads kernel drivers signed by Microsoft when Secure Boot is on.
Nobody else can produce that signature, so the release has to go through the
Windows Hardware Dev Center (Partner Center).

### One-time prerequisites

1. **A registered organization.** EV certificates and the Hardware Developer
   Program are for legal entities; an individual can't get either.
2. **An EV code-signing certificate** from a CA that Microsoft accepts
   (DigiCert, Sectigo, GlobalSign, SSL.com, ...). It normally comes on a
   hardware token or in a cloud HSM.
3. **Registration in the Windows Hardware Developer Program**
   ([Partner Center](https://partner.microsoft.com/dashboard/hardware)),
   using the EV certificate to prove the organization's identity.

### Choose a signing route

| | Attestation signing | WHCP (HLK) certification |
| --- | --- | --- |
| Tests you run | None | Windows Hardware Lab Kit tests for a filter driver (DevFund) on an HLK controller and client |
| Loads with Secure Boot on (Windows 10/11 client) | Yes | Yes |
| Windows Server | No | Yes |
| Windows Update distribution | No (test audiences only) | Yes; can ship automatically when the display is plugged in |
| Microsoft's positioning | "For testing purposes" | Retail |

Attestation signing is enough for a GitHub download. Choose WHCP if you want
Windows Update delivery, or if you want to be safe against Microsoft tightening
attestation policy further. Both routes take the same package from this repo.

### Release steps

```powershell
# 1. Build the unsigned package with your version and legal company name.
.\driver\build.ps1 -Version 1.0.0.0 -Company "Your Company" -Sign None

# 2. Test it first as a test-signed build on a test machine (checklist below):
.\driver\build.ps1 -Version 1.0.0.0 -Company "Your Company"   # test-signed copy

# 3. Create and EV-sign the submission CAB (thumbprint of your EV certificate).
.\driver\build.ps1 -Version 1.0.0.0 -Company "Your Company" -Sign None
.\driver\package-submission.ps1 -CertificateThumbprint <EV-cert-thumbprint>
```

4. In Partner Center, go to **Hardware > Submit new hardware** and upload
   `driver\dist\submission\StudioDisplayBrightness.cab`. For attestation, leave
   the test-signing options unchecked and request the signatures for
   **Windows 10 client x64** and **ARM64** (these cover Windows 11). For WHCP,
   submit the `.hlkx` from your HLK run instead.
5. The first submission registers the package's `ExtensionId`
   (`{2DB501D7-E092-43B6-B7A4-926F235929DF}`) to your organization. Never change
   it: updates with the same ID replace older versions.
6. Download the signed package, then build the user zip. The script refuses
   packages that aren't validly signed by Microsoft:

   ```powershell
   .\driver\package-release.ps1 -SignedPackage "$env:USERPROFILE\Downloads\Signed_<id>.zip"
   ```

7. Publish `driver\dist\release\StudioDisplayBrightness-<version>.zip` as a
   GitHub release.

### Pre-release test checklist

Run these on a test-signed build before each submission and after each Windows
feature update:

- [ ] Install with Memory Integrity (HVCI) **on**; the driver loads (`test-driver.ps1` shows nits).
- [ ] The Settings and Quick Settings sliders appear and change the display; brightness keys work.
- [ ] Unplug and replug the display's USB-C/Thunderbolt cable; the slider disappears and returns.
- [ ] Sleep/resume and reboot; brightness is kept.
- [ ] A laptop's built-in panel keeps its own brightness control with the driver installed.
- [ ] Other monitors (non-Apple, other GPUs) are unaffected.
- [ ] Driver Verifier: `verifier /standard /driver StudioDisplayBrightness.sys`, reboot, then repeat the steps above.
- [ ] `uninstall.cmd` removes it cleanly and the monitors keep working.

## Developer builds (test signing)

Windows decides at boot whether it will load drivers that Microsoft didn't
sign, so the first test needs one restart. After that, every new build can be
tested without restarting: rerun `build.ps1` and `install.ps1`. Each dev build
gets a newer version, so `pnputil` swaps the running driver and restarts the
monitor devices (the screen may flicker once).

**Quick option (one restart, no BIOS change, lasts until the next restart).**
Go to Settings > System > Recovery > Advanced startup > **Restart now**. Then
choose Troubleshoot > Advanced options > Startup Settings > **Restart** and
press **7** ("Disable driver signature enforcement"). Once Windows is back up,
run `.\driver\install.ps1` from an elevated PowerShell. **Run `uninstall.cmd`
before restarting normally**; otherwise Windows refuses the driver at the next
boot and the monitor devices report an error until it's removed.

**Persistent option (test-signing mode).** This requires **Secure Boot to be
disabled** in the UEFI/BIOS settings. From an elevated PowerShell:

```powershell
.\driver\install.ps1 -EnableTestSigning   # suspends BitLocker for one reboot; reboot afterwards
.\driver\install.ps1                      # trusts the test certificate, installs the package
.\driver\test-driver.ps1                  # current brightness in nits
.\driver\test-driver.ps1 -Nits 200 -TransitionMs 500
.\driver\uninstall.ps1 -RemoveTestCertificate -DisableTestSigning
```

`install.ps1` detects Microsoft-signed packages and skips all of the test-mode
steps for them. If a monitor fails to start with the driver attached, it
removes the package again.

## Troubleshooting

- **No slider:** run `test-driver.ps1` (elevated). If it lists no interface,
  the driver found no HID endpoint; check that the display's USB connection
  is attached (some docks drop it). If it reports nits but there's no slider,
  run `Restart-Service DisplayEnhancementService` or sign out and back in.
- **Kernel log:** install with `-EnableDebugLog`, reboot, and watch the
  `StudioDisplayBrightness:` lines in Sysinternals DebugView (Capture Kernel).
- **Stopped working after a Windows update:** the private interface may have
  changed. Please open an issue with your Windows build number.

## Limitations

- With two displays from the same vendor, each monitor binds to the first free
  HID endpoint, so the mapping between them may be swapped.
- The existing CLI/GUI tools keep working next to the driver; brightness they
  set shows up in the Windows slider the next time Windows reads it.
