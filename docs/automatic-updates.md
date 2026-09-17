# Automatic updates

Duckpad embeds Sparkle 2.10.0. Packaged apps check the HTTPS feed on launch (when automatic checks are enabled), then Sparkle schedules checks every six hours. This is polling, not a push notification. Scheduled updates appear as a blue `New version: …` button at the right of every document window's title bar. Clicking it or Help → Check for Updates opens Sparkle's release notes and installation flow. Dismissing or skipping an update clears the reminder; new windows share the same pending update. Manual checks can find skipped versions.

Downloads and installation require user interaction; automatic installation is disabled. Sparkle's installer requests normal application termination, so Duckpad's existing termination coordinator still flushes recovery and handles failures before allowing exit. The installer runs in Sparkle's XPC service outside the editor sandbox. Duckpad's network entitlement handles the download directly.

## Signing and first installation

Apple Developer membership is not required for Sparkle's Ed25519 archive signatures. The public key is embedded in `Packaging/Info.plist`; the private key remains in the macOS login Keychain under Sparkle account `com.namjeongwan.duckpad`. Do not export it into the repository or logs. Back up the signing key securely before changing machines; losing it can prevent updates to ad-hoc-signed installations.

Ad-hoc signing is not Apple notarization and does not remove first-install Gatekeeper checks. Developer ID signing/notarization remains a separate distribution step. Sparkle supports this development configuration, but production update behavior must be verified with the packaged apps, not merely SwiftPM executables.

Existing 0.6.5 and earlier apps have no automatic installer. Users must manually install the first Sparkle-enabled version once. That version can receive subsequent updates. `duckpad-jekyll/appcast.xml` now publishes the signed 0.7.0 (44) ZIP. Do not offer older builds that lack Sparkle.

## Publishing subsequent updates

1. Bump app/helper versions and build numbers, review and merge, then build and verify the universal app using the existing release procedure. Preserve Sparkle's framework symlinks and sign its nested helpers before the framework and app; `build_macos_app.sh` handles this.
2. Package the verified app into DMG and ZIP, publish the verified GitHub Release, and keep the exact ZIP locally.
3. Run `python3 scripts/prepare_sparkle_feed.py /absolute/path/Duckpad-X.Y.Z-universal.zip`. This checks the public release asset's digest, version, embedded updater/public key and feed URL, then invokes Sparkle's `generate_appcast` using the Keychain key. It embeds release notes and signs the full ZIP. No delta updates are generated.
4. Review `duckpad-jekyll/appcast.xml`, commit it through the normal independent-review/PR process, and merge. The Website workflow deploys it with the site. Confirm the live XML and perform an upgrade from the preceding Sparkle-enabled package on a disposable session before announcing completion.

The updater feed and the website download metadata are separate: publishing a GitHub Release alone does not publish its Sparkle feed. Do not change a published archive after generating its signature.

Reference: https://sparkle-project.org/documentation/ and https://sparkle-project.org/documentation/sandboxing/

## Validation for this change

- Twelve presentation tests passed: badge lifecycle/click routing, Korean text, shared update actions, About status completion/cancellation, Escape/reopening, eight-language layout bounds/wrapping across seven update states and existing menu behavior. Six targeted termination tests passed, including cancellation/failure and unsaved recovery.
- The final universal 0.7.0 (44) package passed bundle/framework signature and entitlement verification, Finder/open, bookmark save/relaunch, layout and sandboxed extension smoke checks. Native save-panel UI automation was skipped.
- A disposable, separately identified sandboxed app used a localhost feed and a Keychain-signed archive to upgrade from test version 0.6.5 (43) to test version 0.6.6 (44). Both apps were ad-hoc signed. The scheduled reminder appeared at the upper right, its button opened Sparkle, and dismissal removed the badge. Download, installation and automatic relaunch succeeded; both the unsaved Korean/emoji scratch and edited file were restored, with the original file unchanged. These are local fixture versions, not published releases.
- The compact About window was visually checked in Korean in the packaged app, including Escape close/reopen. The borderless update row and footer were also visually checked in native test-host renders across all eight languages; the German failure state was checked for multiline layout. All eight languages contain the six new strings.
- Apple notarization and execution on Intel hardware were not tested. The 0.7.0 archive matches the published GitHub asset SHA-256, and its Sparkle signature was verified before feed publication. The six-hour interval is configured and delegated to Sparkle; a six-hour wall-clock soak was not performed.
