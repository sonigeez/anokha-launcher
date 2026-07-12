# Release Checklist

The following checks are deliberately split between automated evidence and machine/account-dependent gates. A checkbox is evidence, not optimism wearing a lanyard.

## Automated on the development Mac

- [x] Core/unit/runner suite passes.
- [x] Real temporary user-domain `launchd` bootstrap, query, kickstart, status, output, and exact bootout pass.
- [x] File arguments containing spaces, empty values, and Unicode arrive without shell reparsing.
- [x] Retry-on-failure stops after success; always-restart relaunches after success.
- [x] A TERM-ignoring child process group is killed after the grace period.
- [x] Log rotation and zero-backup policies remain bounded.
- [x] Final local release ZIP extracts with a valid strict signature and both `arm64` and `x86_64` slices.
- [x] Packaged GUI launches and remains running.
- [x] Accessibility inspection exposes the main split view, New Job action, editor fields, command-type controls, validation text, and save actions.

## Required before a public release

- [ ] Sign with the real Developer ID identity.
- [ ] Notarize, staple, extract the final ZIP, and pass Gatekeeper assessment.
- [ ] Fresh install on a clean macOS 14+ user account.
- [ ] Approve, revoke, and re-approve the app in Background Items.
- [ ] Log out/in and verify at-login, scheduled, manual, and keep-running policies.
- [ ] Reboot and verify eligible jobs restart only after login.
- [ ] Verify calendar and interval behavior through sleep/wake.
- [ ] Verify protected-folder denial and recovery guidance.
- [ ] Run a long noisy child and inspect rotation while the GUI is closed.
- [ ] Perform the complete keyboard-only flow with Full Keyboard Access.
- [ ] Perform a complete VoiceOver flow, including conflict and log controls.
- [ ] Smoke-test the final archive on physical Intel hardware.
