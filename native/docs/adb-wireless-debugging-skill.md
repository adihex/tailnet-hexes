---
name: adb-wireless-debugging
description: Pair and connect an authorized Android phone over wireless ADB, including Tailscale, install or update an APK without wiping data, and verify the installed version and launch. Use for wireless debugging, adb pair/connect, installing on a OnePlus phone, changing debugging ports, or diagnosing a built APK that did not actually update the device.
---

# Wireless Android debugging

## Keep the operation scoped

- Confirm the user authorized connecting to and installing on the device.
- Work from the relevant attached project, not a search of the whole machine.
- Use a current Android SDK Platform-Tools `adb`. Inspect `adb version` and
  `adb devices -l`; do not restart the shared ADB server as a first remedy.
- Keep pairing codes, tokens, and credentials out of this skill, source,
  screenshots, persistent files, and shell history.
- Do not uninstall, clear application data, bypass installation confirmation,
  disable a verifier, or change device security settings to make an update work.

## Pairing and connection are different

On Android 11+, ask the person to enable **Developer options → Wireless
debugging**. The **Pair device with pairing code** dialog shows a short-lived
pairing address and code. The main Wireless debugging page shows the connection
address. These use different ports, and the ports can change.

If the device is already paired and connected, skip pairing.

```sh
adb pair "$PAIR_ENDPOINT"
adb connect "$CONNECT_ENDPOINT"
adb devices -l
```

The first command asks for the pairing code. Run it interactively with the
person, or use a tool that can provide it privately through stdin with a
timeout. Do not leave an unattended command waiting for terminal input.
Do not save a real code in a reusable example.

For Tailscale, use the phone's authorized tailnet address and the current
debugging port supplied by the person. mDNS discovery may not cross the tailnet;
an empty discovery result is not proof the device is unavailable. Use an
explicit `adb connect` address rather than scanning unrelated hosts or ports.
If it fails, check that both peers are connected, Wireless debugging remains
enabled, the port is current, and tailnet policy permits it.

## Confirm the target before installing

Set `SERIAL` to the exact serial shown by `adb devices -l`. Include
`-s "$SERIAL"` on every subsequent device command, even if only one device
appears. Check the identity and ABI:

```sh
adb -s "$SERIAL" get-state
adb -s "$SERIAL" shell getprop ro.product.model
adb -s "$SERIAL" shell getprop ro.product.cpu.abi
adb -s "$SERIAL" shell getprop ro.build.version.sdk
```

Discover the APK's package ID, version code, supported ABI, launchable
activity, and icon using the project's SDK `aapt2 dump badging`. Verify its
signature with `apksigner verify --verbose`. For an update, keep the package
ID and signing identity compatible and increment the version code.
Capture the existing package's version and update time with:

```sh
adb -s "$SERIAL" shell dumpsys package "$PACKAGE"
```

Use a bounded parser to display only the relevant metadata, not private
application files or an unbounded dump of device state.

## Install once, then verify

```sh
adb -s "$SERIAL" install -r "$APK"
```

Use a finite timeout or a background terminal with completion notification.
If streaming fails without a useful reason, one direct alternative is:

```sh
adb -s "$SERIAL" install --no-streaming -r "$APK"
```

Do not repeatedly start installers. On OnePlus/OxygenOS, a safety or install
guide may be awaiting the person's approval. A package-specific foreground
activity check can distinguish that from a completed update. An observed
`com.oplus.stdsp` install guide means approval may still be required; it is
not proof the package was installed. Ask the person to approve the normal
confirmation. Never disable that protection.

If installation reports a signature mismatch or downgrade, stop and explain
the conflict. Do not uninstall or wipe the app as a workaround.

After a successful installer result, read the package metadata again and
compare the **installed version code** with the APK. An upload finishing, a
build succeeding, or an app with the same name opening is insufficient proof.
If they do not match, report the update as pending.

## Launch and inspect only the requested app

Use the launchable component discovered from the APK:

```sh
adb -s "$SERIAL" shell am start -W -n "$COMPONENT"
adb -s "$SERIAL" shell pidof "$PACKAGE"
```

An `am start` result can mean an already-running activity was reused. Confirm
the process and installed build before claiming the new app opened. When
the user requests relaunch testing, scope any force-stop to that package;
warn if session-only credentials or unsaved work would be lost.

Inspect logs with an app PID/tag filter and a finite dump, not a continuous
unfiltered logcat. Take an app screenshot or use `adb shell input` only when
authorized, after confirming the requested app is foreground. Avoid capturing
unrelated screens, credentials, or notifications.

For settings regressions, verify both profile switching and persistence
after process restart. A test of source code is not a test of the installed
APK. Do not change real account settings merely to run an automated test;
use isolated test state or get approval for a reversible device check.

## Report evidence precisely

Separate these outcomes:

- **Built:** artifact path, package ID, version code, signature check.
- **Connected:** the explicitly targeted device and its identity.
- **Installed:** the device reports the expected version code.
- **Opened:** the expected component/process was observed.
- **Verified:** name the actual workflow exercised.

State any user approval still required. Never report a pending confirmation
as a successful installation, or a newly created token as authenticating
unless the server actually accepts it.
