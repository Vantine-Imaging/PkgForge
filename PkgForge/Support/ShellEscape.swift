// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Quoting helpers for values interpolated into generated bash (S-13).
///
/// Everything the operator can influence — app names, bundle identifiers,
/// cleanup paths — passes through here. An app called `Bob's App.app` must
/// produce a script that is both valid and non-injectable.
enum ShellEscape {

    /// Wraps a value in single quotes, ending and reopening the quoted run
    /// around any embedded single quote. `Bob's App` becomes `'Bob'\''s App'`.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a literal for use inside a `pgrep -f` / `pkill -f` extended
    /// regular expression. Without this, an app named `Photos (Beta)` yields a
    /// pattern that matches the wrong processes — or nothing at all.
    static func regexLiteral(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            if #"\.^$*+?()[]{}|"#.contains(character) {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// Escapes a literal for `find -name`, whose pattern is an fnmatch glob.
    static func globLiteral(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            if #"\*?["#.contains(character) {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// Escapes a literal for an AppleScript string body, which is then itself
    /// single-quoted for the shell.
    static func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
