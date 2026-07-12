# Security Policy

## Supported versions

The latest release and the current `main` branch receive security fixes.

## Reporting a vulnerability

Use the repository's private security-advisory feature or contact the maintainers privately. Do not open a public issue containing an exploit, private path, token, or user data. Include the affected version, reproduction steps, impact, and any suggested mitigation.

## Explicit limits

- Jobs run with the logged-in user's permissions.
- Environment variables are plaintext and are not secret storage.
- The app does not elevate privileges or manage system daemons.
- User-authorized commands can delete files or perform other destructive work. The app shows the exact execution plan but does not pretend arbitrary commands are safe.
- macOS privacy controls may deny a background job access even when the GUI could select the same file.
