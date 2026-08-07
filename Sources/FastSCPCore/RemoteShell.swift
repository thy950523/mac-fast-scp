import Foundation

/// Pure helpers for building commands that run on the remote shell invoked by
/// `ssh <alias> <cmd>`. Extracted from `SSHExecutor` so the quoting logic (which
/// is safety-critical for any remote `rm`) can be unit-tested directly.
public enum RemoteShell {
    /// Quote a path for the remote shell. `ssh` joins argv with spaces, so each
    /// path must survive shell parsing: a leading `~` becomes a bare `$HOME`
    /// (tilde does not expand inside quotes); the remainder is single-quoted
    /// (with `'\''` for embedded apostrophes). Absolute paths are simply
    /// single-quoted. Preserves spaces and most special characters while still
    /// expanding `~`.
    public static func quote(_ path: String) -> String {
        let body: String
        let prefix: String
        if path == "~" {
            return "$HOME"
        } else if path.hasPrefix("~/") {
            prefix = "$HOME"
            body = String(path.dropFirst(1)) // keeps leading "/"
        } else {
            prefix = ""
            body = path
        }
        let quoted = body
            .split(separator: "'", omittingEmptySubsequences: false)
            .joined(separator: "'\\''")
        return prefix + "'" + quoted + "'"
    }

    /// True only for a single, safe path component: non-empty, no `/`, and not
    /// `.`/`..`. This is what permits `rm -rf <base>/<name>` to target exactly
    /// one entry at the destination and nothing broader — the project's
    /// non-negotiable remote-delete baseline.
    public static func isSafeBasename(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != ".", t != "..", !t.contains("/") else { return false }
        return true
    }
}
