# Native validation

Automated checks cover the native terminal engine/JNI, Rust transport/protocol,
Python PTY and Android input/UI. See the build and test scripts for commands.
Use test fixtures instead of deployment credentials or existing remote sessions.

Automated tests do not replace physical-device acceptance checks. See
[device-checklist.md](device-checklist.md) for manual validation requirements.
APK/build/cache directories are ignored by Git.
