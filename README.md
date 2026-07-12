# Anokha Launcher

Anokha Launcher is a native macOS application for creating and supervising user-level background jobs without hand-writing LaunchAgent property lists. It supports shell commands, directly invoked files with distinct arguments, login and calendar schedules, retry policies, environment variables, bounded logs, live status, and external-change detection.

The app is deliberately not a terminal, a root daemon manager, or a secrets vault.

## Requirements

- macOS 14 Sonoma or newer
- Xcode 16 or newer with the macOS SDK
- Swift 5.10 or newer

## Build and run

```sh
./script/build_and_run.sh
```

That command builds both the GUI and the unprivileged job runner, packages a real app bundle at `dist/AnokhaLauncher.app`, signs it ad hoc for local development, and launches it.

Useful modes:

```sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
```

Run tests:

```sh
swift test --disable-sandbox
```

Build an ad-hoc universal archive for local verification:

```sh
./script/build_release.sh --local
```

Build, notarize, staple, and validate a production release:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
NOTARY_PROFILE="notarytool-profile" \
  ./script/build_release.sh
```

The production path refuses to emit an ad-hoc “release.” That particular lie has wasted enough afternoons already.

## What is installed

Enabled jobs use app-owned labels under `com.anokha.launcher.job.*`. Metadata, runner configurations, runtime status, the stable runner copy, and bounded logs live under `~/Library/Application Support/AnokhaLauncher`. Enabled job plists live under `~/Library/LaunchAgents`. Disabling removes the plist and boots out only that exact service. Quitting the GUI does not stop enabled jobs.

macOS may ask for Background Items approval. The app reports that state and links to the relevant System Settings pane.

## Security model

Jobs run as the logged-in user. The app does not request administrator access and does not install a privileged helper. Environment values are plaintext and must not contain secrets. See [SECURITY.md](SECURITY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Public builds must complete the evidence-backed [release checklist](docs/RELEASE_CHECKLIST.md); universal compilation is not a magical substitute for testing an Intel Mac.

## License

MIT. See [LICENSE](LICENSE).
