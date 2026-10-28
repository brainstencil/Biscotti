import Foundation

/// A field-level validation failure for a person's name or email.
public enum PersonFieldError: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case invalidEmail
}

/// Normalization and validation rules for a person's name and email.
///
/// Pure and SwiftData-free so the store (inside its save) and the editor
/// UI (for inline messages) apply exactly the same rules.
public enum PersonFieldRules {
    /// Longest allowed name, in characters. Shared with AI speaker naming.
    public static let maxNameLength = 120

    /// Trims the name and collapses internal whitespace runs (including
    /// tabs and newlines) to a single space. Casing is kept.
    public static func normalizeName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Validates an already-normalized name. Returns nil when valid.
    public static func validateName(_ normalized: String) -> PersonFieldError? {
        if normalized.isEmpty { return .emptyName }
        if normalized.count > maxNameLength { return .nameTooLong }
        return nil
    }

    /// Trims and lowercases the email. Returns nil when nothing remains,
    /// which means "no email".
    public static func normalizeEmail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Validates an already-normalized email. Returns nil when valid or
    /// absent. The check is deliberately minimal: exactly one `@`, a
    /// non-empty part on each side, and no whitespace.
    public static func validateEmail(_ normalized: String?) -> PersonFieldError? {
        guard let normalized else { return nil }
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty, !parts[1].isEmpty,
              !normalized.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return .invalidEmail }
        return nil
    }

    /// Whether two normalized names count as the same name for collision
    /// purposes (case-insensitive).
    public static func namesCollide(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
