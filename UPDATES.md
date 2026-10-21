# Calshot releases and updates

The source repository is public. Updates are delivered from GitHub Releases using Sparkle 2.10.0, pinned in the Xcode project. Versioned release ZIPs contain a universal macOS app; the `updates` release holds the stable `appcast.xml`. Both the feed and archives require Ed25519 signatures. Extraction waits for signature verification. The app also requires its normal Apple code signature.

Settings → General shows version/build, check status, persistent errors, manual check and device-local automatic check/download choices. Production defaults are a six-hour check and automatic download/install on quit. Development builds disable automatic checks/downloads and allow manual feed checks. No beta channel or forced minimum-version lockout is implemented.

A requested relaunch waits for active capture/OCR, agent work, pending questions/reviews, calendar writes, connection setup and sync. It never approves or cancels work. Restart decisions and bridge gating live in Swift. Completed calendar receipts and history are preserved. The user may decline or skip a release through Sparkle.

## Signing keys

The Sparkle private key was created in this Mac’s login Keychain under account `com.calshot.updates`. Only its public key belongs in Info.plist. Back up the private key securely; losing it prevents future updates signed with that identity. Never commit private keys, certificates or exported credentials.

The published feed currently has no installer entries. Its signature was verified after an anonymous GitHub download. No notarized public installer has been published.

## First distribution setup

This Mac has Apple Development signing but no **Developer ID Application** identity. Obtain that distribution certificate through the Apple Developer account before shipping. The release script refuses a development identity, and requires successful notarization, stapling and Gatekeeper assessment before producing publishable artifacts.

For local releases, install the Developer ID certificate in Keychain and create a `notarytool` credential profile. Set `SIGNING_IDENTITY` to the complete Developer ID Application identity, `NOTARY_PROFILE` to that profile, then run:

```sh
script/release_macos.sh 1.0.0 101
```

For GitHub Actions, configure the `release` environment with these encrypted secrets:

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate with private key |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting the P12 |
| `APPLE_NOTARY_KEY` | App Store Connect API private key, P8 contents |
| `APPLE_NOTARY_KEY_ID` | API key ID |
| `APPLE_NOTARY_ISSUER` | API issuer ID |
| `SPARKLE_PRIVATE_KEY` | Existing Sparkle private key exported securely from Keychain |

Set environment variable `MACOS_SIGNING_IDENTITY` to the complete Developer ID Application identity. Restrict release environment deployment to trusted version tags and maintainers. All secrets stay in the ephemeral release job, are removed on completion, and are never available to pull-request CI. These distribution secrets have not been uploaded or configured yet.

## Publishing

Commit and push the complete tested source (including current uncommitted account, sharing and website work) before creating a version tag. Do not tag the old remote source. Push `v1.0.0` to run `.github/workflows/release-macos.yml`. The workflow runs WebUI/native tests, creates a universal Release archive, verifies signing and notarization, staples the app, signs its ZIP and feed, publishes the installer, then replaces the stable feed. The build number is the workflow run number plus 100; it must exceed every published build. A retry after a versioned GitHub release was already created should be recovered deliberately by verifying its assets before updating the feed; it must never replace a published installer silently.

Normal CI has read-only repository access and runs the WebUI and native suites. Release jobs serialize feed changes. Existing clients keep working if a release check fails; errors remain in Settings. A successful build or empty-feed check does not prove replacement/relaunch works: verify an upgrade between two notarized builds with isolated fixture data before distributing to users.

## Verification completed

- WebUI production build and all 64 UI tests passed.
- All 144 native tests passed, including deferred restart, task/review/sync blocking and bridge validation.
- The native app checked the anonymous public signed feed successfully through Sparkle; the downloaded XML signature also verified independently.
- A development-only archive in an isolated temporary folder generated a signed feed successfully; it was never uploaded or installed.
- Native compact/expanded windows and browser viewports at 920 × 650 and 1440 × 900 were inspected. Inline failures and long status text fit without horizontal page overflow.
- Release script syntax, workflow YAML, plist/project syntax and refusal of an Apple Development identity were checked. GitHub release CI, notarization and an actual upgrade between two distribution builds remain unverified until distribution credentials are configured.
