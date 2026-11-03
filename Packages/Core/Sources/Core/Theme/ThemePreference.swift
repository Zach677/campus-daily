import Foundation

/// The chosen theme, kept in the App Group's preferences so the widget and the Live Activities
/// draw with it too. Only the app writes it, compared and written in one step inside the shared
/// lock (`set(_:under:)`); the extensions only read. Nothing stored, or a value this build
/// doesn't know: 暖橙.
public struct ThemePreference {
    public static let key = PreferenceKey.theme
    private let storage: any PreferenceStorage

    public init(storage: any PreferenceStorage) { self.storage = storage }

    public var theme: AppTheme { AppTheme(stored: storage.object(forKey: Self.key) as? String) }

    /// Stores `theme` unless it is already stored, inside `lock`. A lock that can't be taken
    /// throws and nothing is written.
    public func set(_ theme: AppTheme, under lock: any SharedLock) throws {
        try lock.locked {
            guard storage.object(forKey: Self.key) as? String != theme.rawValue else { return }
            storage.set(theme.rawValue, forKey: Self.key)
        }
    }

    /// The preferences the app and its extensions share: the App Group's, or this process's own
    /// when it has no group (tests, an install re-signed without one).
    public static func sharedStorage(appGroup: String? = AppIdentity.usableAppGroup) -> any PreferenceStorage {
        appGroup.flatMap { UserDefaults(suiteName: $0) } ?? UserDefaults.standard
    }

    /// The theme the app last chose, as the widget and Live Activities read it when they draw.
    public static func shared() -> AppTheme { ThemePreference(storage: sharedStorage()).theme }
}
