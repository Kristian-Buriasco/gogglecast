import Foundation

// User-visible text that SwiftUI does not localize by itself (AppKit alerts and menus,
// messages built in model code, strings held in variables) goes through `L`.
//
// The English text is the key, so English needs no translation file. Other languages
// ship as `<lang>.lproj/Localizable.strings` in the app bundle's Resources folder; see
// docs/localization.md. SwiftUI initialisers that take a literal (`Text("Save")`,
// `Button("Save")`, `Toggle(...)`, `.help(...)`) look up the same files on their own.
//
// Format keys use plain C specifiers (%@ for strings, %lld for integers, %.1f for
// doubles, %% for a literal percent sign). Translations may reorder arguments with
// positional specifiers (%2$@ ... %1$@).

enum Localization {
    /// While true, `L` returns the English key. Used for text that must stay English
    /// whatever the system language is (the copied diagnostics and health reports).
    @TaskLocal static var forceEnglish = false

    /// Runs `body` with every `L` lookup returning the English text.
    static func english<T>(_ body: () throws -> T) rethrows -> T {
        try $forceEnglish.withValue(true, operation: body)
    }

    /// Looks `key` up in `bundle`, falling back to the key itself (the English text).
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        if forceEnglish { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Same as `string`, then substitutes `args` into the format.
    static func format(_ key: String, _ args: [CVarArg], bundle: Bundle = .main) -> String {
        String(format: string(key, bundle: bundle), arguments: args)
    }
}

/// Localized plain string.
func L(_ key: String, comment: String = "") -> String {
    Localization.string(key)
}

/// Localized format string with arguments (`%@`, `%lld`, `%.1f`, ...).
func L(_ key: String, _ args: CVarArg..., comment: String = "") -> String {
    Localization.format(key, args)
}
