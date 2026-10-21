# Calshot releases and updates

The source repository is public. Updates are delivered from GitHub Releases using Sparkle 2.10.0, pinned in the Xcode project. Versioned releases offer a drag-to-Applications DMG for website/GitHub downloads and a separate universal app ZIP for automatic updates; the `updates` release holds the stable `appcast.xml`. The update feed and ZIP archives require Ed25519 signatures; the DMG supports either an explicitly selected ad hoc signed/unnotarized release or Developer ID signing and notarization. Extraction waits for signature verification. Ad hoc signatures preserve bundle integrity but do not establish an Apple-verified publisher identity.

Settings → General shows version/build, check status, persistent errors, manual check and device-local automatic check/download choices. Production defaults are a six-hour check and automatic download/install on quit. Development builds disable automatic checks/downloads and allow manual feed checks. No beta channel or forced minimum-version lockout is implemented.

A requested relaunch waits for active capture/OCR, agent work, pending questions/reviews, calendar writes, connection setup and sync. It never approves or cancels work. Restart decisions and bridge gating live in Swift. Completed calendar receipts and history are preserved. The user may decline or skip a release through Sparkle.

## Signing keys

The Sparkle private key was created in this Mac’s login Keychain under account `com.calshot.updates`. Only its public key belongs in Info.plist. Back up the private key securely; losing it prevents future updates signed with that identity. Never commit private keys, certificates or exported credentials.

## Free distribution (current release route)

No paid Apple account is required for this route. Build a universal **Release** archive with ad hoc code signatures and no hardened runtime library validation, then generate the Ed25519-signed ZIP/update feed and verified DMG:

```sh
RELEASE_MODE=unnotarized script/release_macos.sh 1.0.0 101
```

The Sparkle signing key stays in login Keychain under `com.calshot.updates`, or may be supplied as a private file using `SPARKLE_KEY_FILE`. Never print or commit it. Build numbers must strictly increase. This is a release archive, not the Debug packaging fixture.

Users open the DMG, drag Calshot to Applications, and try to open it. Because Apple has not notarized it, macOS may block the first launch. They can allow that app through System Settings → Privacy & Security → Open Anyway. See [Apple’s instructions](https://support.apple.com/102445). Never tell users to disable Gatekeeper globally. Ad hoc signing can also cause macOS to request permissions again after an update; preserve account data and explain OS permission prompts normally.

## Optional notarized distribution

The default local script mode remains `notarized` to avoid silently bypassing its existing trust checks. Install a Developer ID Application certificate and a notarytool credential profile, then set `SIGNING_IDENTITY` and `NOTARY_PROFILE` before running the script without `RELEASE_MODE=unnotarized`. This mode verifies hardened runtime, notarization/stapling and Gatekeeper assessment for the app and DMG.

## Publishing

Commit and push the tested public client before creating a version tag. Keep website/backend source in the private repository. Publish `Calshot-VERSION.dmg`, `Calshot-VERSION.zip` and `SHA256SUMS` to that tag’s GitHub Release, then upload the verified signed `appcast.xml` to the `updates` release. Never overwrite a published installer; recover interrupted publishing by comparing existing assets first. Release notes and the website must disclose unnotarized installation.

GitHub Actions defaults to the unnotarized route. The job uses the `release` environment and encrypted secret `SPARKLE_PRIVATE_KEY` (configured at repository scope). Configure variable `RELEASE_MODE=notarized` to opt into Developer ID distribution; that additionally requires `MACOS_SIGNING_IDENTITY`, `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_NOTARY_KEY`, `APPLE_NOTARY_KEY_ID`, and `APPLE_NOTARY_ISSUER`. Signing material stays in the ephemeral job and is removed on completion. The build number is the workflow run number plus 1000 and must exceed every published build.

An Ed25519-signed feed/archive preserves update verification on the free route. A successful build/feed check does not prove replacement/relaunch works; an actual upgrade between two public builds remains to be tested with isolated data.

## Verification completed

- WebUI production build and all 64 UI tests passed.
- All 144 native tests passed, including deferred restart, task/review/sync blocking and bridge validation.
- The native app checked the anonymous public signed feed successfully through Sparkle; the downloaded XML signature also verified independently.
- A development-only archive in an isolated temporary folder generated a signed feed successfully; it was never uploaded or installed.
- Native compact/expanded windows and browser viewports at 920 × 650 and 1440 × 900 were inspected. Inline failures and long status text fit without horizontal page overflow.
- Release script syntax, workflow YAML and embedded shell syntax pass. Website’s 17 tests, workspace’s 64 tests and full native suite’s 144 tests pass for the free release path. GitHub release CI, notarization and installation of a subsequent public update remain unverified.

## DMG installer

`script/package_dmg.sh` uses pinned `dmgbuild` tooling in an isolated Python virtual environment. Its Finder window contains `Calshot.app`, an Applications shortcut and a drag arrow. By default it requires a Developer ID signature and stapled ticket. Explicit `--unnotarized` accepts only a valid ad hoc signed app. In notarized mode, the release workflow also signs, notarizes, staples and assesses the resulting disk image before uploading it to GitHub Releases as `Calshot-VERSION.dmg`.

The public website selects only that DMG from a stable release. `Calshot-VERSION.zip` remains the Sparkle payload. DMG generation happens after appcast generation to keep the two delivery paths separate. `SHA256SUMS` covers both final artifacts.

For a **local packaging inspection only**, using a signed development app:

```sh
script/package_dmg.sh --fixture build/DerivedData/Build/Products/Debug/Calshot.app build/PackagingChecks/Calshot-packaging-preview.dmg
```

This creates a volume named **Calshot Packaging Preview**. Do not publish that development fixture as a release. Creating a DMG does not make the embedded development build distribution-ready; use the Release archive and explicit unnotarized route above for free distribution.

DMG packaging verification: a local development fixture was built, mounted read-only and inspected in Finder with Calshot, the drag arrow and the Applications shortcut. The embedded app passed deep/strict code-signature verification and matched the source app metadata. Production packaging rejected the development identity as expected. Developer ID signing/notarization remains an optional, untested route.
