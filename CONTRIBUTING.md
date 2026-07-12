# Contributing

1. Open an issue before a large behavioral or storage-format change.
2. Keep launchd mappings inside the compiler and system operations behind typed clients.
3. Add externally observable tests; do not pin tests to SwiftUI view structure.
4. Run `swift test --disable-sandbox` and `./script/build_and_run.sh --verify` before submitting a change.
5. Never add analytics, network calls, privileged helpers, secret-looking fixtures, or mutation of unrelated LaunchAgents.

Changes to persistence or job generation must document migration and rollback behavior. Real launchd tests must use unique exact labels and unconditional cleanup.
