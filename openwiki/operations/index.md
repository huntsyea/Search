# Files

- [Build, sign and release](build-and-release.md) - How Search is built and shipped — swift build vs ./build.sh, the assembled app bundle (stripped binary, dSYM, drawn icon, Info.plist), ad-hoc vs Developer ID signing and the passkeys provisioning profile, separate arm64 and Intel builds, DMG/ZIP/appcast and the signed appcast, notarisation, publish.sh checks, the Homebrew tap, and the OpenWiki CI workflow.
- [Self-update](self-update.md) - How Search updates itself without a framework or daemon — the per-architecture signed appcast, hourly checks, the stages from found to ready, ZIP hash and Developer ID verification of the new bundle, the two-rename swap beside the running app, the DMG fallback, relaunch, what it never touches, and the tests.
