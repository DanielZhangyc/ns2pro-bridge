# Working on NS2 Pro Bridge

- This is an independent macOS controller adapter. Never add game resources, keys, saves, or game-runtime dependencies.
- Do not launch the app, activate virtual HID, or connect Bluetooth while the user is using the physical controller elsewhere. Build and pure tests are safe; real hardware tests require an available controller.
- Use `swift test --jobs 2` and `bash scripts/build-app.sh`. The build script signs but does not launch or install.
- Distinguish codec/socket/build validation from physical controller and target-game evidence. Do not claim console-identical force or universal game support.
- Preserve MIT attribution. New or revised explanatory source comments use Chinese followed by English.
- Keep rumble leases bounded on the BLE queue. Disconnect, sleep and exit must clear input and stop rumble. Native dual-band ownership must discard stale ordinary effects.
- Only commit and push when requested; inspect identity and destination first. Never rewrite history without authorization.
