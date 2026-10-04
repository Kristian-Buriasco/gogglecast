# Security

Please report vulnerabilities privately through GitHub's "Report a vulnerability" button
(Security tab), not in a public issue.

Things worth knowing:
- The app registers a root helper daemon (`GogglesHelper`) that owns the USB device and talks to the app over XPC.
- The optional web viewer is plain HTTP, off by default and localhost-only unless "Allow other devices" is on. Treat its token as a casual guard, not strong authentication.
- Stream keys, SRT passphrases, the web token, the GitHub token and webhook URLs are stored in the macOS Keychain.
- Event hooks run only programs you choose in Settings; nothing is run remotely. URL-scheme and AppleScript automation can be turned off in Settings > Advanced.
