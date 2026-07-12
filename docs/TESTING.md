# Testing

## Unit and runner tests

```sh
swift test --disable-sandbox
```

Tests cover validation, direct arguments, deterministic property lists, schedule summaries and DST behavior, external-change fingerprints, diagnostics, bounded rotation, runner exit status, and retry-until-success behavior.

## Real launchd integration test

The integration test uses a unique temporary label and temporary plist rather than writing to `~/Library/LaunchAgents`. Cleanup always targets the exact service label.

```sh
ANOKHA_RUN_LAUNCHD_INTEGRATION_TESTS=1 swift test --disable-sandbox \
  --filter LaunchdLifecycleIntegrationTests
```

Standard-directory persistence, Background Items approval, logout/login, reboot, sleep/wake, protected-folder denial, and Intel hardware remain manual release checks because pretending those are portable unit tests would be nonsense.

## Release archive

```sh
./script/build_release.sh --local
```

The script extracts the final ZIP—not merely the staging app—and verifies its signature, property list, and both `arm64` and `x86_64` slices. Production mode additionally requires Developer ID credentials, notarizes, staples, and runs Gatekeeper assessment.
