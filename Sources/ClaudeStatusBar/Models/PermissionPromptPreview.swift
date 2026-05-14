import Foundation

/// Pure helpers for deriving display strings from a `PermissionPromptRequest`.
/// Lives in the model layer (Foundation only) so the panel UI and any future
/// banner fallback can share it without reimplementing the field heuristics.
public enum PermissionPromptPreview {

    /// Single-line body extracted from the most user-meaningful field of `input`.
    /// Returns an empty string if no recognised field carries a string value.
    public static func bodyPreview(for request: PermissionPromptRequest, maxLength: Int = 200) -> String {
        for key in ["command", "file_path", "url", "path", "query"] {
            if let v = request.input[key]?.stringValue, !v.isEmpty {
                return v.count > maxLength ? String(v.prefix(maxLength)) + "…" : v
            }
        }
        return ""
    }

    /// Compact one-line summary for banners / tooltips, e.g. `"Bash: rm -rf foo"`.
    public static func compactSummary(for request: PermissionPromptRequest, maxBody: Int = 80) -> String {
        let body = bodyPreview(for: request, maxLength: maxBody)
        return body.isEmpty ? request.toolName : "\(request.toolName): \(body)"
    }

    /// Human-friendly session label for the panel header. Prefers the cwd
    /// basename ("my-project"); falls back to a short session id; nil when
    /// neither is supplied so the panel can hide the row entirely.
    public static func sessionName(for request: PermissionPromptRequest) -> String? {
        if let cwd = request.cwd, !cwd.isEmpty {
            let basename = (cwd as NSString).lastPathComponent
            if !basename.isEmpty { return basename }
        }
        if let sid = request.sessionId, !sid.isEmpty {
            return "session " + String(sid.prefix(8))
        }
        return nil
    }
}
