# Hexes native client

One NanoUI/Zig client for macOS and Android. The Expo app in `hexes-jojo`
is a protocol and UX reference, not a dependency or something to replace.

- Zig 0.17.0; pin NanoUI to a revision and package hash.
- Keep every file under 600 lines.
- Never open a window while testing. Use `zig build test` and the
  `--nanoui-snapshot` / `--nanoui-script` flags.
- Tests never read/write Keychain, the real clipboard, or production state.
- Never persist tokens in source, fixtures, preferences, logs, or screenshots.
- Network callbacks run on the main thread. Generations reject responses
  belonging to an old server or conversation.
- Long polling is server-held, not periodic refresh. Back off failures;
  stop on authentication errors. Submit retries reuse their request ID.
- Validate desktop and narrow layouts. Build Android when an SDK/NDK is
  available; report missing prerequisites rather than claiming APK proof.

```sh
zig build
zig build test
zig fmt --check build.zig src
zig build -Dtarget=aarch64-linux-android
sh tools/bundle-macos.sh
```
