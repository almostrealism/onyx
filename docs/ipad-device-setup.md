# Getting the iPad app onto a real iPad

Where this stands (November 2026) and what to try next. The goal is the
iPad app in the next release, tested on the user's own iPad over USB-C on
the Mac Studio.

## The setup

- iPad Pro 11-inch, 3rd generation (iPad13,7), serial `P6659VQ0PQ`, UDID
  `00008103-0001542911EA001E`. Now on iPadOS 27.3 beta (build 24C5037i);
  it was on an early 27.0 beta (24A5380l).
- Mac Studio: macOS 27.2.1, Xcode 27.2 (27B52), with its first-launch
  components, the Metal toolchain and the iOS simulator installed.
- Pairing and installing run as `michael`, not `worker`: Xcode's device
  pairing (CoreDevice) is per account, and only `michael` is an admin.

## What happened

1. **Trust was tapped, but `./package-ios.sh --list` showed nothing.**
   Tapping Trust pairs the iPad for Finder and backups. Xcode's installs
   need a second, CoreDevice, pairing. An unpaired device also reports no
   "reality" field, and the script's filter dropped it. Fixed in 5b7d410.
2. **No Developer Mode in Settings.** That option appears only once a
   supported Xcode has prepared the device. Xcode 16.3 on macOS 15.7 was
   too old for iPadOS 27, so the Mac was upgraded to macOS 27 and Xcode
   27.2.
3. **After the upgrade the listing showed a garbage row.** In Xcode 27,
   a device that isn't paired reports no UDID or name, and the empty
   fields shifted the script's columns. Fixed in 2220989 and 5b5d30f. The
   script now names such a device by serial number, because CoreDevice's
   own "identifier" differs between accounts on the same Mac.
4. **Pairing fails: `devicectl manage pair` gives CoreDevice error
   1014.** The iPad's pairing state is `unsupported`. The same happened
   on 27.0 beta and 27.3 beta.

## What does work

Everything below Xcode reaches the iPad:

- **USB.** `usbmuxd` lists it by its real UDID.
- **Lockdown.** The device's basic service answers with its name and
  version, so Trust is in place.
- **The developer link.** The USB network interface CoreDevice uses is up.

Only Xcode's device service can't talk to it. It sees just the serial
number and ECID, and `devicectl device info details` says "This device
does not support acquiring a usage assertion".

## What to try next, in order

1. **Xcode → Window → Devices and Simulators**, as `michael`, with the
   iPad unlocked. Xcode often states the real problem there ("Preparing
   device", an unsupported iPadOS version, or a pairing prompt). The
   command line doesn't.
2. **Restart the Mac Studio.** `remoted` and some CoreDevice services
   started before Xcode's first-launch install replaced the device
   frameworks.
3. **Install the Xcode 27.3 beta** beside the current one. Xcode 27.2
   probably doesn't know iPadOS 27.3 yet. As `michael`:
   `sudo xcode-select -s /Applications/Xcode-beta.app` and
   `sudo xcodebuild -runFirstLaunch`.
4. **Reset the iPad's trust.** Go to Settings → General → Transfer or
   Reset iPad → Reset → Reset Location & Privacy, then replug and tap
   Trust. A full erase is the last resort.

Once `./package-ios.sh --list` shows the iPad `paired`, the rest follows
[ios-today.md](ios-today.md) ("A device"):

1. Run `./package-ios.sh`.
2. Turn on Developer Mode when the iPad offers it; the iPad restarts.
3. Run `./package-ios.sh` again.

## Checks that help

- `./package-ios.sh --list`, as `michael`. The PAIRING column should read
  `paired`, not `unsupported`.
- `xcrun devicectl device info details --device P6659VQ0PQ`. A working
  device shows its name, version and dozens of capabilities. A broken one
  shows two.
