#!/bin/zsh
# Builds a Release .pkg of PkgForge itself into dist/.
#
# With no signing certificates installed, produces an ad-hoc-signed app in an
# unsigned pkg — deployable via Jamf Pro/MDM (which skips Gatekeeper), but
# manual double-click installs will be blocked.
#
# Once a "Developer ID Application" identity exists in the keychain it is used
# automatically; likewise "Developer ID Installer" for the pkg, and a
# notarytool keychain profile (default name: pkgforge-notary) for notarization
# + stapling. One-time setup lives in README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PkgForge"
IDENTIFIER="com.vantine.PkgForge"
NOTARY_PROFILE="${NOTARY_PROFILE:-pkgforge-notary}"

echo "==> Generating Xcode project"
xcodegen generate

APP_SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true

rm -rf build
mkdir -p build
BUILD_LOG="build/xcodebuild.log"

sign_args=()
if [[ -n "${APP_SIGN_ID:-}" ]]; then
  echo "==> Building Release (signing with: $APP_SIGN_ID)"
  sign_args=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$APP_SIGN_ID" OTHER_CODE_SIGN_FLAGS=--timestamp)
else
  echo "==> Building Release (ad-hoc signing)"
  echo "    WARNING: no Developer ID Application identity — using ad-hoc signing."
  echo "    The pkg will deploy via Jamf/MDM, but Gatekeeper blocks manual installs."
  sign_args=(CODE_SIGN_IDENTITY=-)
fi

if ! xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath build build "${sign_args[@]}" > "$BUILD_LOG" 2>&1; then
  echo "    BUILD FAILED — last 30 lines of $BUILD_LOG:"
  tail -30 "$BUILD_LOG"
  exit 1
fi
echo "    Build succeeded"

APP_PATH="build/Build/Products/Release/$APP_NAME.app"

# PkgForge cannot do its job from inside a sandbox: it execs pkgbuild, ditto,
# codesign, security and pkgutil. Fail the release rather than ship a build
# that silently refuses to build anything (P-2).
if codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null \
    | plutil -convert xml1 -o - - 2>/dev/null \
    | grep -A1 'com.apple.security.app-sandbox' | grep -q '<true/>'; then
  echo "    ERROR: the built app is sandboxed. It will not be able to run pkgbuild."
  exit 1
fi
echo "    Verified: App Sandbox is disabled"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
PKG="dist/$APP_NAME-$VERSION.pkg"
mkdir -p dist

echo "==> Building $PKG"
pkgbuild --component "$APP_PATH" --install-location /Applications \
  --identifier "$IDENTIFIER" --version "$VERSION" "$PKG"

INSTALLER_SIGN_ID=$(security find-identity -v 2>/dev/null \
  | grep -o '"Developer ID Installer: [^"]*"' | head -1 | tr -d '"') || true

if [[ -n "${INSTALLER_SIGN_ID:-}" ]]; then
  echo "==> Signing pkg with: $INSTALLER_SIGN_ID"
  productsign --sign "$INSTALLER_SIGN_ID" "$PKG" "$PKG.signed"
  mv "$PKG.signed" "$PKG"

  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Notarizing (keychain profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG"
  else
    echo "    NOTE: no notary profile '$NOTARY_PROFILE' — skipping notarization."
    echo "    One-time setup: xcrun notarytool store-credentials $NOTARY_PROFILE"
  fi
else
  echo "    NOTE: no Developer ID Installer identity — pkg left unsigned (fine for Jamf deployment)."
fi

echo "==> Done"
ls -lh "$PKG"
pkgutil --check-signature "$PKG" || true
