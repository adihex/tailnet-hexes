# Hexes native

A shared NanoUI/Zig client for macOS and Android. This is native, custom-drawn
UI, not a webview. Both existing servers remain unchanged.

## Build

Requires **Zig 0.17.0** and, on macOS, Xcode's command-line tools.
NanoUI is pinned to a revision and verified package hash.

```sh
cd native
zig build
zig build test
sh tools/bundle-macos.sh   # zig-out/Hexes.app, locally ad-hoc signed
# For faster local iteration, use: sh tools/bundle-macos.sh Debug
```

Launch `zig-out/Hexes.app` yourself, or `zig build run`. Nothing is installed
over the Chrome apps. This is a development build, not notarized distribution.

The app icon is **Night Moth**, selected from concept 21. Its editable master
is `resources/icon.svg`; the Mac ICNS and full-bleed Android PNG are included.
After changing the artwork, run `python3 tools/generate-icons.py` on a Mac
with `resvg` installed. Direct binary launches use the same mark as the bundle.

For Android, install Java and the Android SDK (platform API 36, build tools,
NDK). On macOS, the optional bootstrap downloads pinned official archives,
verifies Google's checksums, and extracts them into ignored `.android-sdk/`.
It does not change the system SDK or silently accept SDK licenses:

```sh
python3 tools/android-sdk.py
ANDROID_HOME="$PWD/.android-sdk" zig build -Dtarget=aarch64-linux-android
# zig-out/android/Hexes.apk, debug-signed
adb -s "$SERIAL" install -r zig-out/android/Hexes.apk
# Optional offscreen tests on the device, not in the installed app's state:
ANDROID_HOME="$PWD/.android-sdk" zig build test-bin \
  -Dtarget=aarch64-linux-android --prefix zig-out/android-tests
adb -s "$SERIAL" push zig-out/android-tests/bin/hexes-tests /data/local/tmp/hexes-tests
adb -s "$SERIAL" shell /data/local/tmp/hexes-tests
```

Alternatively, point `ANDROID_HOME` / `ANDROID_NDK_HOME` at an existing SDK.
Use the intended device's serial or wireless connection address for `SERIAL`;
the wireless pairing port and connection port are different. The APK uses
package ID `net.adihex.hexes`, supports arm64 devices, and requires API 29+.

Both devices need Tailscale connected to the servers' tailnet.

## Connect

Choose **Hexes** (cloud) or **Hexes CV**, then paste that server's owner token
or full `/login?token=…` link. Tokens are separate between profiles; a link
for the other server is rejected. Never put tokens in source or command lines.

macOS can remember the token in **Keychain**. Android currently keeps it
**in memory for this session only**: there is no plaintext-file fallback.
Android Keystore-backed persistence is follow-up work, not an implemented feature.

## Separate profile settings

Hexes and Hexes CV have independent device-local settings, stored under their
stable profile keys. Each keeps its own theme and macOS **Remember in Keychain**
choice. Switching profiles restores its choices immediately; restarting the
app restores both profiles' saved choices. Tokens remain separate Keychain
accounts, not preference values.

The previous shared theme is retained for Hexes only; CV starts at **Follow
desktop** unless it already has its own saved theme. Each profile caches only
its own server's desktop palette. Signing out clears that profile's token and
drafts, not the other profile's drafts or either profile's appearance choices.
These settings do not change the web app, OMP, or server-side model configuration.

## Themes

**Appearance** is available before and after sign-in on both layouts. It offers
the same 22 Omarchy palettes as the original web app, plus **System**, **Light**,
**Dark**, and **Follow desktop**. The choice is saved for the selected profile on
this device; it does not change another profile, the web app, or the server.

Follow desktop reads the selected server's `/api/theme` on connection,
reconnection, or **Refresh desktop theme**. It falls back to Tokyo Night when
the server has no palette. Unlike the web client, it does not check every six
seconds. Wallpaper, tiling, and the web theme-reveal animation are not ported.
Base palette colors match the web presets; native controls use contrast-checked
text and status colors rather than promising pixel-identical web rendering.

## Native core milestone

- Profile switching, masked sign-in, optional macOS Keychain persistence.
- Searchable sessions, working/sleeping status, and Jojo.
- Native conversation rendering, Markdown, code, tool-output disclosure,
  and session links from Jojo replies.
- Live response text through the server's acknowledged long-poll protocol.
- Sending, steering a running agent, stopping, and loading older history.
- Read-only uncommitted-file list and unified diffs.
- Desktop split view; stacked phone navigation; keyboard-aware NanoUI fields.
- Cmd-K searches, Cmd-L focuses the composer, Cmd-R reconnects.
  Return sends; Shift-Return inserts a newline.

`hexes-jojo/App.js` informed sign-in, Jojo's `pip` protocol, history, and
mobile navigation. This does not modify or replace that Expo app. Voice
dictation, attachments, Files/Terminal/Browser, schedules, notifications,
provider settings, spawning/forking and environment controls remain in the
existing clients. Jojo can still be asked to manage sessions.

NanoUI's Android backend currently lacks composing IMEs and accessibility.
Those are framework limitations, especially relevant to non-Latin typing
and TalkBack; this client does not claim to solve them.

## Safety and reconnection

Only fixed HTTPS origins are used. There is no certificate-verification bypass.
Credentials and drafts never go into logs or fixtures. Normal requests use
`pocket_auth` and `X-Pocket`, matching the existing clients.

One long-poll chain acknowledges successful events. Server restarts reset its
cursor. Profile/view generations ignore old callbacks; closing an old poll
releases the server-side connection. Network failures back off to 30 seconds,
and 401/403 stops reconnecting until sign-in.

A failed submit retains the draft and request ID. Retry unchanged to avoid
duplicate delivery after an ambiguous network failure. Changing the message
creates a new submission. Switching conversations/servers is held while a
submit is in flight. Drafts are kept per profile and conversation in memory.

Changes are read-only: there is no revert, checkout, archive, or delete action.
Tests never send messages or modify production state.

## Headless validation

```sh
zig fmt --check build.zig src
zig build test
zig build test -Dportable=true
zig-out/bin/hexes --hexes-demo --nanoui-snapshot=zig-out/workspace.png
zig-out/bin/hexes --hexes-demo --hexes-phone --hexes-theme=gruvbox \
  --nanoui-snapshot=zig-out/phone-gruvbox.png
zig-out/bin/hexes --nanoui-snapshot=zig-out/sign-in.png
```

`--hexes-demo` is explicitly labelled sample data and never uses the network
or Keychain. Snapshot runs never read Keychain or save theme preferences.

Opt-in production **read-only** check (GET sessions, live snapshots and diffs;
no Jojo creation, submits, or other mutations):

```sh
zig-out/bin/hexes --hexes-read-only --nanoui-wait=10 \
  --nanoui-snapshot=zig-out/live.png
# Add --hexes-profile=cv or --hexes-session=42 as needed.
```

Read-only mode uses no credentials, so it works only if the server permits
tailnet reads without an owner token. It is a validation mode, not a sign-in
bypass. An authenticated-only server should refuse it. A read-only snapshot
exits nonzero unless it received the session list and acknowledged live
events, including the selected conversation's view. Allow more wait time on
slow connections or for large conversations.
