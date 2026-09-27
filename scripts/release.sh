#!/bin/bash
set -euo pipefail

# DrDoctor release script (modelled on drtagger for Mac's).
# Usage: scripts/release.sh 1.2.0
#        NOTARIZE=0 scripts/release.sh 1.2.0   # sign only, no notarization (dev)
#        PUBLISH=0  scripts/release.sh 1.2.0   # notarize, but no tag / GitHub release / tap bump
#        INSTALL=0  scripts/release.sh 1.2.0   # don't replace /Applications/DrDoctor.app
#
# Builds a Release .app signed with Developer ID (hardened runtime, secure
# timestamps), packs it into a DMG, notarizes and staples it, and leaves the
# artifacts in ./dist. With PUBLISH=1 (default) it tags v<VERSION>, pushes,
# creates the GitHub release with the DMG attached and bumps version + sha256
# in the cask at $TAP_DIR/Casks/drdoctor.rb (clone of prietus/homebrew-drdoctor).

VERSION="${1:?Usage: scripts/release.sh VERSION}"
NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"
INSTALL="${INSTALL:-1}"

GH_REPO="prietus/drdoctor"
TAP_DIR="${TAP_DIR:-/opt/homebrew/Library/Taps/prietus/homebrew-drdoctor}"
CASK_FILE="Casks/drdoctor.rb"

TEAM_ID="LFTD9T269J"
SIGN_ID="Developer ID Application: carlos prieto ortiz ($TEAM_ID)"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="/tmp/drdoctor-release-build"
OUT_DIR="$PROJECT_DIR/dist"
# Unversioned .app so copying to /Applications overwrites the previous one;
# the DMG carries the version.
APP_OUT="$OUT_DIR/DrDoctor.app"
DMG_OUT="$OUT_DIR/DrDoctor-${VERSION}.dmg"

cd "$PROJECT_DIR"

if [ "$PUBLISH" = "1" ]; then
    echo "==> Pre-flight checks for publishing..."
    if [ "$NOTARIZE" != "1" ]; then
        echo "ERROR: PUBLISH=1 requires NOTARIZE=1 (never ship an un-notarized build)." >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo "ERROR: working tree is dirty — commit or stash before publishing." >&2
        exit 1
    fi
    if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
        echo "ERROR: releases are cut from main." >&2
        exit 1
    fi
    if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
        echo "ERROR: tag v${VERSION} already exists." >&2
        exit 1
    fi
    if [ ! -f "$TAP_DIR/$CASK_FILE" ]; then
        echo "ERROR: cask not found at $TAP_DIR/$CASK_FILE (tap prietus/drdoctor, or set TAP_DIR)." >&2
        exit 1
    fi
    gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated." >&2; exit 1; }
fi

if [ "$NOTARIZE" = "1" ]; then
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 || {
        echo "ERROR: notarytool profile '$KEYCHAIN_PROFILE' not found (set NOTARY_PROFILE)." >&2
        exit 1
    }
fi

echo "==> Cleaning previous build artifacts..."
rm -rf "$DERIVED" "$APP_OUT" "$DMG_OUT"
mkdir -p "$OUT_DIR"

echo "==> Building Release v${VERSION}..."
xcodebuild \
    -project DrDoctor.xcodeproj \
    -scheme DrDoctor \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build \
    | grep -E "^(warning:|error:|\*\*)" || true

BUILT_APP="$DERIVED/Build/Products/Release/DrDoctor.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: build did not produce $BUILT_APP" >&2
    exit 1
fi

echo "==> Copying to $APP_OUT..."
cp -R "$BUILT_APP" "$APP_OUT"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_OUT"
codesign -dv --verbose=4 "$APP_OUT" 2>&1 \
    | grep -E "(Identifier|TeamIdentifier|Authority|Timestamp|Runtime)" || true

echo "==> Creating DMG..."
hdiutil create -volname "DrDoctor" -srcfolder "$APP_OUT" -ov -format UDZO "$DMG_OUT" >/dev/null

if [ "$NOTARIZE" != "1" ]; then
    echo
    echo "==> Notarization skipped (NOTARIZE=$NOTARIZE)."
    echo "    DMG: $DMG_OUT (signed but NOT notarized)"
    exit 0
fi

echo "==> Submitting to Apple notarization service (this can take 1-5 min)..."
xcrun notarytool submit "$DMG_OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_OUT"
xcrun stapler staple "$APP_OUT"

echo "==> Final Gatekeeper assessment (should now pass):"
spctl --assess --type exec --verbose=4 "$APP_OUT"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_OUT"

SHA256="$(shasum -a 256 "$DMG_OUT" | awk '{print $1}')"
echo "==> sha256: $SHA256"

if [ "$INSTALL" = "1" ]; then
    echo "==> Installing to /Applications..."
    pkill -x DrDoctor 2>/dev/null || true
    sleep 1
    rm -rf /Applications/DrDoctor.app
    cp -R "$APP_OUT" /Applications/
fi

if [ "$PUBLISH" != "1" ]; then
    echo
    echo "==> Publish skipped (PUBLISH=$PUBLISH)."
    echo "    App: $APP_OUT (notarized + stapled)"
    echo "    DMG: $DMG_OUT"
    exit 0
fi

echo "==> Tagging v${VERSION} and pushing to origin..."
git tag -a "v${VERSION}" -m "DrDoctor ${VERSION}"
git push origin main "v${VERSION}"

echo "==> Creating GitHub release v${VERSION} with $(basename "$DMG_OUT") attached..."
gh release create "v${VERSION}" "$DMG_OUT" \
    --repo "$GH_REPO" \
    --title "DrDoctor ${VERSION}" \
    --notes "Signed and notarized build for macOS 14 Sonoma or later. Install with \`brew install --cask prietus/drdoctor/drdoctor\`, or open the DMG and drag DrDoctor to Applications.

sha256 \`${SHA256}\`" \
    --generate-notes

echo "==> Bumping cask to ${VERSION} in ${TAP_DIR}..."
(
    cd "$TAP_DIR"
    git pull -q --ff-only
    sed -i '' -E \
        -e "s|^(  version \").*(\")$|\1${VERSION}\2|" \
        -e "s|^(  sha256 \").*(\")$|\1${SHA256}\2|" \
        "$CASK_FILE"
    git add "$CASK_FILE"
    git commit -q -m "drdoctor ${VERSION}"
    git push -q
)

echo
echo "==> Done."
echo "    App:     $APP_OUT"
echo "    DMG:     $DMG_OUT"
echo "    Release: https://github.com/${GH_REPO}/releases/tag/v${VERSION}"
echo "    Install: brew install --cask prietus/drdoctor/drdoctor"
