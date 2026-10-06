# Contributing

Issues and pull requests are welcome.

- Build and test: `cd Apps/GogglesView && swift test` (also `Helper/GogglesHelper` and `Tools/gvcli`). See `docs/dev-setup.md` for signing and the helper.
- Hardware matters: please say what you tested on real goggles and what you could only unit-test.
- Keep changes focused, match the surrounding style, and add tests for pure logic.
- Protocol notes live in `docs/`; if you capture new behavior, document it there (no captures containing serial numbers or other personal data).
- By contributing you agree your work is licensed under GPL-3.0-or-later, like the rest of the project.
- Releasing: bump `CFBundleShortVersionString`/`CFBundleVersion` in `Apps/GogglesView/BundleResources/Info.plist`, move the `[Unreleased]` entries in `CHANGELOG.md` under a new `## [X.Y.Z] - date` heading, run `scripts/make-dmg.sh`, tag `vX.Y.Z`, then `gh release create vX.Y.Z --notes-file <(scripts/release-notes.sh X.Y.Z) dist/GogglesView-X.Y.Z.dmg`.
