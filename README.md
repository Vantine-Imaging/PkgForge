# PkgForge

Turns a dropped `.app` into a signed, Jamf-ready installer `.pkg` with
generated pre/postinstall cleanup scripts — and, optionally, uploads the result
straight into Jamf Pro.

macOS 26, SwiftUI, no `sudo`, no privileged helper.

## Build and run

```
xcodegen generate
open PkgForge.xcodeproj
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and
gitignored. `scripts/release.sh` produces a distributable `.pkg` in `dist/`,
signing and notarizing automatically when the identities are present.

### App Sandbox is off, deliberately

PkgForge shells out to `/usr/bin/pkgbuild`, `/usr/bin/ditto`,
`/usr/bin/codesign`, `/usr/bin/security` and `/usr/sbin/pkgutil`. A sandboxed
process cannot exec any of them, so the entitlement is `false` and
`scripts/release.sh` fails the release if a build ever comes out sandboxed.
Hardened Runtime stays on.

## What it does

1. **Drop an app.** The whole window is a drop target, and a replacement is
   accepted at any point. `Info.plist` is parsed with
   `PropertyListSerialization`, so binary plists work. A bundle with no
   `CFBundleIdentifier` is rejected rather than given a synthesised one — a
   wrong identifier makes the package a silent upgrade of something else.
2. **Adjust the form.** Identifier, version, install location, quit timeout,
   the two stale-path lists, the signing identity and the output folder. Paths
   support `${BUNDLE_ID}` and `${APP_NAME}`.
3. **Build.** Payload staged with `ditto`, scripts written at mode `0755`,
   `pkgbuild --ownership recommended`, then `pkgutil --check-signature` and
   `--payload-files` for verification. Tool output streams into the log
   inspector as it happens; failures show `pkgbuild`'s own stderr.
4. **Upload to Jamf Pro** (optional). See below.

The signing picker only lists **Developer ID Installer** identities. An
application identity produces a package macOS refuses to install, so it must
never be selectable.

**Preview Scripts** in the toolbar shows exactly what will run as root on every
managed Mac, before you build.

## Generated scripts

The preinstall matches the running app by the executable path it was launched
from (`pgrep -f` on `<install-location>/<AppName>.app/Contents/MacOS/`), not by
process name — names truncate at 15 characters and collide. It asks the console
user to quit via `launchctl asuser … osascript`, polls to the timeout, then
escalates `SIGTERM` → `SIGKILL`. If the app is still there and "abort if it
cannot be stopped" is on, it exits 1 so the Jamf policy fails: half-replacing a
bundle that is still mapped into a running process is worse than failing.

LaunchDaemons and LaunchAgents named in the cleanup lists are `launchctl
bootout`ed before their plists are deleted.

"Remove stray copies" is **off by default** and stays that way deliberately: it
is the only option that can delete something outside the install location. It
searches `/Applications` and every user's `~/Applications` two levels deep for a
bundle with a matching *filename*, so PkgForge checks each hit's
`CFBundleIdentifier` against the package's before deleting it — two unrelated
vendors ship a `Console.app`, and a filename match alone is not evidence of
identity. Per-user paths are applied across
`/Users/*`, skipping `Shared`, `Guest` and dot-directories.

The postinstall sets `root:wheel`, strips group/other write, clears
`com.apple.quarantine`, and verifies the code signature (warning only).

### The install location is pinned

Left to itself `pkgbuild` writes a `<relocate>` block into the package. At
install time the installer looks the bundle identifier up on the target Mac and,
if it finds an existing copy somewhere other than the install location — a
user's `~/Applications`, `/Applications/Utilities`, an old copy on another
volume — it puts the payload *there* instead.

For a managed deployment that is never what was meant, and with these scripts it
is actively harmful: the preinstall has already removed the app from the install
location, and the postinstall then finds nothing where it expects and fails the
policy while the payload sits somewhere else entirely.

So PkgForge runs `pkgbuild --analyze`, sets `BundleIsRelocatable` to false for
every component, and passes the result back via `--component-plist`. The
resulting package carries an empty `<relocate/>`. The **Always install to the
location above** toggle turns this off for the rare case where relocation is
wanted; the postinstall then downgrades its missing-bundle check to a warning,
because the bundle legitimately may be elsewhere.

### Additional scripts

A flat package declares its script phases in `PackageInfo`, and `pkgbuild`
emits exactly two:

```xml
<scripts>
    <preinstall file="./preinstall" timeout="600"/>
    <postinstall file="./postinstall" timeout="600"/>
</scripts>
```

`preflight`, `postflight`, `preupgrade` and `postupgrade` are pre-10.5
bundle-package phases. Nothing in a modern flat package declares them and
`installer` never runs them, so PkgForge does not pretend to offer them.
Anything extra goes *inside* the two real scripts:

- **Preinstall additions** — your own bash, placed either before the app is
  stopped or after all cleanup, just before the script exits.
- **Postinstall additions** — placed after ownership, permissions and
  quarantine are corrected, before the signature check.
- **Bundled files** — copied into the package's `Scripts` directory. macOS
  never runs them; your additions call them as
  `"$(/usr/bin/dirname "$0")/name"`. Anything starting with `#!` gets mode
  755, everything else 644. A file named `preinstall` or `postinstall` is
  rejected rather than allowed to replace the generated one.

`$APP_NAME`, `$BUNDLE_ID`, `$APP_PATH`, `$INSTALL_LOCATION`, `$CONSOLE_USER`,
`$CONSOLE_UID` and `log()` are all in scope for your snippets.

Because those snippets are code rather than data they are spliced in verbatim,
so the build runs `/bin/bash -n` over both finished scripts and **fails** if
either is not valid bash. An unbalanced quote stops the build instead of
producing a package that installs fine everywhere and silently does nothing.

Every interpolated value is shell-escaped, regex-escaped for `pgrep`, or
glob-escaped for `find`, as appropriate. An app called `Bob's Test App.app`
produces valid, non-injectable bash — there is a test for it.

### Two deliberate deviations from the spec

- **N-3** asks for filenames sanitised to letters, digits, hyphen and
  underscore. Applied literally that turns `2.1.0` into `2-1-0`, which makes
  the package unrecognisable downstream for no safety gain. The app *name*
  is reduced to that set; the *version* additionally keeps dots. Leading dots
  and `..` are still stripped.
- **Section 6** does not say what postinstall should do if the bundle is not
  where it was expected. It exits 1. Reaching that point means ownership was
  never corrected on a bundle in `/Applications`, which is the exact
  privilege-escalation case S-14 exists to close.

## Jamf Pro upload

Section 10 of the requirements puts this out of scope for v1; it is included
here because it was asked for.

### Saved logins

Settings → **Jamf Pro** stores as many instances as you like and switches
between them. Credentials live in the login Keychain, keyed by URL + auth mode
+ account; only the non-secret parts are in `UserDefaults`. **Test Connection**
validates before saving.

Two auth modes:

- **API Client** (preferred) — Settings → System → API Roles and Clients. The
  role needs **Create**, **Read** and **Update** on *Packages*, plus **Read** on
  *Categories*.
- **Jamf Pro Account** — username and password, exchanged for a bearer token.

### Uploading

After a successful build, **Upload to Jamf Pro…** opens a sheet with the
package record fields (display name, category, priority, info, notes, reboot
required and the suppression flags). Before uploading it looks for an existing
package with the same filename and offers to replace that record instead of
silently creating a duplicate.

The upload uses the Jamf Pro API: `POST /v1/packages` to create or
`PUT /v1/packages/{id}` to update, then `POST /v1/packages/{id}/upload`. The
multipart body is staged to a temp file and streamed from disk, so a
multi-gigabyte package is not held in memory, and a SHA-256 computed during
that pass is sent with the record. Progress is reported live.

**This needs Jamf Pro 11.5 or later**, with a cloud distribution point as the
principal DP. Older instances have no upload endpoint; you get a clear error
rather than a hang. Any 4xx from Jamf is surfaced with the server's own
response body, which is the only useful thing to read when a package record is
rejected.

Metadata from a successful upload is remembered per bundle identifier and
prefilled next time.

## Profiles

After each successful build the configuration is saved to
`~/Library/Application Support/PkgForge/Profiles/<bundleID>.json`. Dropping the
same app again prefills everything from it and takes **only** the version from
the new bundle. The cleanup path lists are the only part of this that requires
real thought and they do not change between versions — persisting them is what
makes the second build a two-click operation. Settings → **Profiles** lists and
deletes them.

## Test status

Verified mechanically against a fixture app named `Bob's Test App.app`
(apostrophe, space, binary `Info.plist`, `CFBundleName` deliberately different
from the filename):

| Acceptance test | Status |
| --- | --- |
| 1. Signed third-party app populates correctly | ✅ (`codesign --display` parsing) |
| 2. Binary `Info.plist` parses | ✅ |
| 3. Scripts reference the on-disk filename, not the display name | ✅ |
| 4. Non-app folder and `.dmg` rejected cleanly | ✅ |
| 5. `pkgutil --check-signature` on unsigned build | ✅ (signed path needs an identity) |
| 6. Graceful quit of a running app | ✅ (executed against a sandboxed install location) |
| 7. Escalation ladder on a `SIGSTOP`ped app | ✅ at the `SIGTERM` rung — a stopped process is still terminated by `SIGTERM`, so the `SIGKILL` rung and the `exit 1` abort could not be provoked without an unkillable process |
| 8. Installed bundle is `root:wheel`, no quarantine | ⬜ needs a real install as root |
| 9. Bogus stale path deleted and logged | ✅ |
| 10. Second build prefills saved cleanup lists | ✅ (profile round-trip) |
| 11. Apostrophe + space produce valid bash | ✅ (`bash -n`, plus execution) |

Tests 5 (signed), 6 and 8 need a test Mac and a Developer ID Installer identity
to finish end to end. The Jamf upload path is written against the documented
API and has not been exercised against a live server.

## Not implemented

Out of scope per section 10 and left that way: notarization/stapling of the
*output* package, `productbuild` distribution packages, end-user prompting UI,
and signing the `.app` itself. Queueing several dropped bundles (I-5, MAY) is
not implemented; extra items in a multi-drop are ignored with a notice.
