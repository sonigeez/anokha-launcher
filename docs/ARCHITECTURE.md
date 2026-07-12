# Architecture

## System boundary

Anokha Launcher owns only labels in `com.anokha.launcher.job.*`. It manages user LaunchAgents in the logged-in `gui/<uid>` domain and never calls `sudo`, creates a LaunchDaemon, or boots out a whole domain.

Dynamic per-job property lists require the legacy `~/Library/LaunchAgents` mechanism. `SMAppService` is the preferred modern API for static helpers embedded in a signed bundle, but it cannot register an arbitrary number of user-authored dynamic jobs. The app still uses `SMAppService.statusForLegacyPlist(at:)` to distinguish Background Items approval from an ordinary launch failure.

## Modules

- `AnokhaCore` contains the domain model, validation, deterministic typed property-list compiler, execution-plan compiler, repository, launchd client, diagnostics, schedule calculations, log service, and runner engine. It has no SwiftUI dependency.
- `AnokhaJobRunner` is an unprivileged executable installed atomically at a stable path in Application Support. Every generated LaunchAgent executes this app-owned runner.
- `AnokhaLauncher` is the SwiftUI application. It uses a macOS list/detail layout and talks to the system through `JobService`.

## Why a runner exists

Plain `StandardOutPath` and `StandardErrorPath` files are never rotated by launchd. They can grow until the disk fills while the GUI is closed. The runner instead spawns the configured child with POSIX argument vectors, pipes both output streams, and rotates each stream to one 5 MB current file plus one 5 MB backup.

The runner also records start time, child PID, exit code or signal, retry count, and current state in an atomic status file. `launchctl print` is intentionally treated as best-effort because its output is documented as unstable.

File jobs are spawned directly with `posix_spawn`: the executable path and each argument remain distinct. Shell jobs explicitly spawn `/bin/zsh` with `-lc` and the original command as one argument. No File-mode argument is joined into shell text.

## Lifecycle mapping

| Product policy | LaunchAgent behavior | Runner behavior |
| --- | --- | --- |
| At login | `RunAtLoad = true` | Run once; optionally retry failures |
| Calendar schedule | `StartCalendarInterval` | Run once; optionally retry failures |
| Repeat interval | `StartInterval` | Run once; optionally retry failures |
| Keep running | `RunAtLoad = true`, `KeepAlive = true` | Restart after every child exit |
| Manual only | No automatic trigger | Start only after `kickstart` |

Scheduled restart-on-failure is implemented inside the runner. Combining a schedule with `KeepAlive = { SuccessfulExit = false }` would implicitly enable `RunAtLoad` and run immediately at login, which is not the promised behavior.

Calendar schedules use local time. Calendar firings during sleep are coalesced on wake. Interval firings during sleep or while the job is already running are missed. Monthly days that do not exist in a month are skipped.

## Persistence and transactions

Metadata is versioned Codable JSON in Application Support. Runner configurations and status use separate atomic JSON files. Property lists are generated from a typed property-list tree with sorted dictionary keys and stable paths; timestamps and display names never enter the plist.

Enable and update operations validate first, install the stable runner, write configuration and plist atomically, bootstrap the exact plist, and roll back the previous files if bootstrap fails. Disable removes the persistent plist before `bootout`, preventing a crash between steps from resurrecting the job at the next login.

The repository stores a canonical semantic SHA-256 fingerprint of the installed plist. Formatting-only edits do not conflict. A missing, unreadable, symlinked, or semantically changed plist blocks mutation until the user inspects, adopts, restores, or stops managing it.

## Distribution

The app is intentionally unsandboxed because a sandboxed GUI cannot promise durable access to arbitrary user-selected scripts, working directories, and dynamic LaunchAgents. Production releases should use Developer ID signing, Hardened Runtime, and notarization. `script/build_release.sh` builds universal arm64/x86_64 binaries and supports both signing and `notarytool` submission.
