#!/bin/bash
# Builds a Release app and a .dmg under build/.
#   SIGN_IDENTITY  "Developer ID Application: …" (default: ad-hoc "-", for local testing only)
#   TEAM_ID        10-character team ID, passed as DEVELOPMENT_TEAM (recommended with SIGN_IDENTITY)
#   NOTARY_PROFILE a `xcrun notarytool store-credentials` profile in your keychain (optional)
#   SPARKLE_ACCOUNT keychain account of the Sparkle EdDSA key (default: gridura)
# With NOTARY_PROFILE the notarized .dmg is also added to appcast.xml (the Sparkle feed), with the version's
# sections of CHANGELOG.md (English, the default) and CHANGELOG.tr.md (Turkish) as its release notes.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
VERSION=$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "version not found in project.yml" >&2; exit 1; }
BUILD_NUMBER=$(sed -n 's/^ *CFBundleVersion: *"\(.*\)"/\1/p' project.yml)
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "CFBundleVersion in project.yml must be an integer" >&2; exit 1; }
BUILD=build
APP_NAME="Gridura"
DMG="$BUILD/Gridura-$VERSION.dmg"
REPO_URL="https://github.com/Gorke07/Gridura"
APPCAST=appcast.xml
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-gridura}"
# Release notes per language; the first is the appcast's default and the second its Turkish alternative.
CHANGELOG_EN=CHANGELOG.md
CHANGELOG_TR=CHANGELOG.tr.md

# Release notes: the version's section of a changelog without its heading (Sparkle shows the version itself)
# and without the compare-link definitions that follow the last section.
release_notes() {
  awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on && /^\[[^]]+\]: / { next }
    on { print }' "$1" | sed -e '/./,$!d'
}
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  # Checked before the long build and notarization, not after.
  for CHANGELOG in "$CHANGELOG_EN" "$CHANGELOG_TR"; do
    [[ -n "$(release_notes "$CHANGELOG")" ]] || { echo "$CHANGELOG has no \"## [$VERSION]\" section (the release notes)" >&2; exit 1; }
  done
  if [[ -f "$APPCAST" ]] && grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST"; then
    echo "$APPCAST already lists build $BUILD_NUMBER: increase CFBundleVersion in project.yml" >&2; exit 1
  fi
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"
xcodegen generate --spec project.yml --quiet

SIGN_FLAGS=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES)
if [[ "$IDENTITY" != "-" ]]; then SIGN_FLAGS+=(OTHER_CODE_SIGN_FLAGS="--timestamp"); fi
if [[ -n "${TEAM_ID:-}" ]]; then
  SIGN_FLAGS+=(DEVELOPMENT_TEAM="$TEAM_ID")
elif [[ "$IDENTITY" != "-" ]]; then
  echo "warning: SIGN_IDENTITY is set but TEAM_ID is not; Xcode may refuse to sign without a development team." >&2
fi

xcodebuild build \
  -project Gridura.xcodeproj \
  -scheme Gridura \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD/DerivedData" \
  -quiet "${SIGN_FLAGS[@]}"

APP="$BUILD/DerivedData/Build/Products/Release/$APP_NAME.app"
SPARKLE_BIN="$BUILD/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

# Sparkle's helpers come ad-hoc signed and Xcode re-signs only the framework itself; notarization needs every
# executable signed with our identity and the hardened runtime. The app is not sandboxed, so Sparkle installs
# without its XPC services and they are removed (sparkle-project.org/documentation/sandboxing).
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE_FW/XPCServices" "$SPARKLE_FW/Versions/B/XPCServices"
RESIGN=(codesign --force --sign "$IDENTITY" --options runtime)
if [[ "$IDENTITY" != "-" ]]; then RESIGN+=(--timestamp); fi
"${RESIGN[@]}" "$SPARKLE_FW/Versions/B/Autoupdate"
"${RESIGN[@]}" "$SPARKLE_FW/Versions/B/Updater.app"
"${RESIGN[@]}" "$SPARKLE_FW"
"${RESIGN[@]}" --preserve-metadata=entitlements,requirements,flags "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
# Capture first: `grep -q` exiting early would SIGPIPE codesign and trip pipefail.
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null)
if grep -q "com.apple.security.get-task-allow" <<<"$ENTITLEMENTS"; then
  echo "app requests com.apple.security.get-task-allow; notarization would reject it" >&2; exit 1
fi
SIGNATURE=$(codesign -d --verbose=2 "$APP" 2>&1)
grep -q "flags=.*runtime" <<<"$SIGNATURE"
if [[ "$IDENTITY" != "-" ]]; then
  for CODE in "$APP" "$SPARKLE_FW" "$SPARKLE_FW/Versions/B/Autoupdate" "$SPARKLE_FW/Versions/B/Updater.app"; do
    DETAILS=$(codesign -dvv "$CODE" 2>&1)
    grep -q "^Authority=Developer ID Application" <<<"$DETAILS" || { echo "$CODE is not signed by a Developer ID Application authority" >&2; exit 1; }
    grep -q "^Timestamp=" <<<"$DETAILS" || { echo "$CODE signature has no secure timestamp" >&2; exit 1; }
  done
fi

STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# The MIT license and the third-party notices (Sparkle) travel with the app.
cp LICENSE THIRD_PARTY_NOTICES.md "$STAGE/"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

if [[ "$IDENTITY" == "-" ]]; then
  echo "Built $DMG with an ad-hoc signature (not for distribution: set SIGN_IDENTITY)."
  exit 0
fi

codesign --sign "$IDENTITY" --timestamp "$DMG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
  echo "$RESULT"
  field() { python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1], ""))
except Exception: print("")' "$1" <<<"$RESULT"; }
  STATUS=$(field status)
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization failed (status: ${STATUS:-unknown})." >&2
    SUBMISSION_ID=$(field id)
    if [[ -n "$SUBMISSION_ID" ]]; then
      echo "Notary log:" >&2
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 \
        || echo "Could not fetch the notary log (retry: xcrun notarytool log $SUBMISSION_ID --keychain-profile \"$NOTARY_PROFILE\")." >&2
    fi
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"

  # Sparkle feed: generate_appcast signs the .dmg with the EdDSA key from the keychain and adds an item that
  # downloads the GitHub Release asset, with the English notes (a .md named like the .dmg) embedded; existing
  # items are kept as they are. The Turkish notes are then added beside them.
  FEED="$BUILD/appcast"
  NOTES_TR="$BUILD/release-notes-tr.md"
  NOTES_EN="$BUILD/release-notes-en.md"
  mkdir -p "$FEED"
  cp "$DMG" "$FEED/"
  release_notes "$CHANGELOG_EN" >"$FEED/$(basename "$DMG" .dmg).md"
  cp "$FEED/$(basename "$DMG" .dmg).md" "$NOTES_EN"
  release_notes "$CHANGELOG_TR" >"$NOTES_TR"
  if [[ -f "$APPCAST" ]]; then cp "$APPCAST" "$FEED/appcast.xml"; fi
  "$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
    --link "$REPO_URL/releases" --embed-release-notes \
    --maximum-versions 0 --maximum-deltas 0 "$FEED"
  ITEM_URL="$REPO_URL/releases/download/v$VERSION/$(basename "$DMG")"
  grep -q "url=\"$ITEM_URL\".*sparkle:edSignature=" "$FEED/appcast.xml" \
    || { echo "the appcast item for $ITEM_URL is missing or has no EdDSA signature" >&2; exit 1; }
  python3 Scripts/localize-appcast.py "$FEED/appcast.xml" "$ITEM_URL" en "tr=$NOTES_TR"
  cp "$FEED/appcast.xml" "$APPCAST"
  echo "Updated $APPCAST with build $BUILD_NUMBER. Publish the release first, so the feed never points at a missing file:"
  echo "  gh release create v$VERSION \"$DMG\" --title \"Gridura $VERSION\" --notes-file \"$NOTES_EN\""
  echo "  git add $APPCAST && git commit -m \"chore: appcast for $VERSION\" && git push"
else
  echo "Signed but not notarized (set NOTARY_PROFILE to notarize)."
fi
echo "Built $DMG"
