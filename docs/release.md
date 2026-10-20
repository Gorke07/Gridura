# Releasing

Updates are delivered with [Sparkle](https://sparkle-project.org): the app reads `appcast.xml` from `SUFeedURL`
and installs only archives signed with the EdDSA key behind `SUPublicEDKey` (both set in `project.yml`).

## Requirements

Xcode 26+, `xcodegen` and `python3` on `PATH`.

## One-time setup (the person who releases)

1. **Developer ID Application certificate** from your Apple Developer account, installed in this Mac's keychain.
   Check with `security find-identity -v -p codesigning`.
2. **Notarization profile** (nothing is written to the repository):
   `xcrun notarytool store-credentials gridura-notary --apple-id <email> --team-id <TEAMID>`
   or with an App Store Connect API key:
   `xcrun notarytool store-credentials gridura-notary --key <AuthKey.p8> --key-id <KEYID> --issuer <ISSUER-UUID>`
3. **Sparkle signing key.** The private key lives in the login keychain under the account `gridura`; its public
   half is `SUPublicEDKey` in `project.yml`. Sparkle's tools appear after the first build under
   `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
   - Check: `generate_keys --account gridura -p` must print the `SUPublicEDKey` value.
   - **Back it up:** `generate_keys --account gridura -x <file>`, keep the file in a password manager, then delete it.
     If the key is lost, installed copies can never be updated again.
   - Move it to another Mac: `generate_keys --account gridura -f <file>`.
4. **Repository URL.** `SUFeedURL` (`project.yml`) and `REPO_URL` (`Scripts/build-release.sh`) point at
   `https://github.com/Gorke07/Gridura`; change both if the repository lives elsewhere.

## Releasing

1. Bump `CFBundleShortVersionString` and increase `CFBundleVersion` in `project.yml` (Sparkle compares builds).
2. Rename `## [Unreleased]` to `## [<version>] - <date>` in `CHANGELOG.md` (English) and `CHANGELOG.tr.md` (Turkish) and list the
   same changes in both; these are the notes users see in the update window.
3. Run

```bash
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" TEAM_ID=<TEAMID> NOTARY_PROFILE=gridura-notary Scripts/build-release.sh
```

Output: `build/Gridura-<version>.dmg` (signed, notarized, stapled) and an updated `appcast.xml`. Without
`SIGN_IDENTITY` the script builds an ad-hoc signed local copy that Gatekeeper rejects on other Macs.

4. Publish in this order, so the feed never points at a missing file:
   1. `gh release create v<version> build/Gridura-<version>.dmg --title "Gridura <version>" --notes-file build/release-notes-tr.md`
   2. commit and push `appcast.xml` to `main`.

`build/` is wiped on every run: copy the `.dmg` elsewhere to keep older releases. To withdraw a release, delete its
entry from `appcast.xml` and push.

Release notes are English by default with a Turkish alternative (`xml:lang`); Sparkle shows the one matching the
user's language. A build number already in `appcast.xml` stops the script before building.

## Checklist

- [ ] Self-tests pass (`GRIDURA_SELFTEST=…`, see `docs/IMPLEMENTATION_STATUS.md`) and the Release build succeeds.
- [ ] `project.yml` version bumped and `CFBundleVersion` increased.
- [ ] Both changelogs have the version's section with the same changes.
- [ ] With the previous release installed, **Update** in About shows the new version with its notes and installs it.
- [ ] The `.dmg` opens on a clean user account without a Gatekeeper warning.
