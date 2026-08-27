#!/bin/zsh
#
# Copyright 2026 Vantine Imaging LLC
# SPDX-License-Identifier: Apache-2.0
#
# Builds a Release .pkg of PkgForge itself into dist/.
#
# With no signing certificates installed, produces an ad-hoc-signed app in an
# unsigned pkg — deployable via Jamf Pro/MDM (which skips Gatekeeper), but
# manual double-click installs will be blocked.
#
# Once a "Developer ID Application" identity exists in the keychain it is used
# automatically; likewise "Developer ID Installer" for the pkg, and a
# notarytool keychain profile for notarization + stapling. Defaults to
# "pkgforge-notary"; set NOTARY_PROFILE=<name> to use a different one. One-time setup lives in README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PkgForge"
IDENTIFIER="com.vantine.PkgForge"
NOTARY_PROFILE="${NOTARY_PROFILE:-pkgforge-notary}"

# Resolves a signing identity to its SHA-1 fingerprint, preferring the one that
# expires last.
#
# Signing by common name breaks the moment a team reissues a certificate: both
# are in the keychain with identical names and codesign refuses the ambiguous
# match outright. Fingerprints are unique.
newest_identity() {
  local prefix="$1"
  local -a shas
  shas=(${(f)"$(security find-identity -v -p basic 2>/dev/null \
    | grep "\"$prefix" | awk '{print $2}')"})
  (( ${#shas} )) || return 1

  local tmp best_sha="" best_epoch=0 sha enddate epoch
  tmp=$(mktemp -d)
  security find-certificate -c "$prefix" -a -Z -p > "$tmp/all" 2>/dev/null

  for sha in $shas; do
    awk -v want="$sha" '
      /^SHA-1 hash:/ { hash = $3 }
      /-----BEGIN CERTIFICATE-----/, /-----END CERTIFICATE-----/ { if (hash == want) print }
    ' "$tmp/all" > "$tmp/cert.pem"
    [[ -s "$tmp/cert.pem" ]] || continue
    enddate=$(openssl x509 -in "$tmp/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
    epoch=$(date -j -f "%b %e %H:%M:%S %Y %Z" "$enddate" +%s 2>/dev/null) || continue
    if (( epoch > best_epoch )); then
      best_epoch=$epoch
      best_sha=$sha
    fi
  done
  rm -rf "$tmp"

  [[ -n "$best_sha" ]] || return 1
  print -r -- "$best_sha"
  if (( ${#shas} > 1 )); then
    print -r -- "    NOTE: ${#shas} \"$prefix\" certificates in the keychain;" >&2
    print -r -- "    using the one expiring $(date -r $best_epoch '+%Y-%m-%d')." >&2
  fi
}

describe_identity() {
  security find-identity -v -p basic 2>/dev/null | grep "$1" \
    | sed -E 's/.*"(.*)"/\1/' | head -1
}

echo "==> Generating Xcode project"
xcodegen generate

APP_SIGN_ID=$(newest_identity "Developer ID Application") || true

rm -rf build
mkdir -p build
BUILD_LOG="build/xcodebuild.log"

sign_args=()
if [[ -n "${APP_SIGN_ID:-}" ]]; then
  echo "==> Building Release (signing with: $(describe_identity "$APP_SIGN_ID"))"
  echo "    fingerprint: $APP_SIGN_ID"
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

# The debug entitlement is injected into any build with base entitlements
# injected — Release included, unless CODE_SIGN_INJECT_BASE_ENTITLEMENTS is off.
# The notary service rejects every executable carrying it, so a release built
# with it can be signed and can never be notarized.
if codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null     | plutil -convert xml1 -o - - 2>/dev/null     | grep -A1 'com.apple.security.get-task-allow' | grep -q '<true/>'; then
  echo "    ERROR: the built app carries com.apple.security.get-task-allow."
  echo "    That is a debug entitlement; Apple will refuse to notarize it."
  echo "    Check CODE_SIGN_INJECT_BASE_ENTITLEMENTS is NO for Release."
  exit 1
fi
echo "    Verified: no debug entitlement"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
PKG="dist/$APP_NAME-$VERSION.pkg"
mkdir -p dist

echo "==> Building $PKG"
pkgbuild --component "$APP_PATH" --install-location /Applications \
  --identifier "$IDENTIFIER" --version "$VERSION" "$PKG"

INSTALLER_SIGN_ID=$(newest_identity "Developer ID Installer") || true

if [[ -n "${INSTALLER_SIGN_ID:-}" ]]; then
  echo "==> Signing pkg with: $(describe_identity "$INSTALLER_SIGN_ID")"
  echo "    fingerprint: $INSTALLER_SIGN_ID"
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
