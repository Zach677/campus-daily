import Foundation

/// The diagnostics older builds kept (导出热水诊断 is gone and nothing writes them any more):
/// `Water/diagnostics.json`, the credential-lifetime lines in the Keychain item
/// `shared.credentialLog`, a report left in the temporary folder by an export, and the scan note
/// `WaterSession/last-scan.json` (written only where a much older build had made that folder).
public enum RetiredDiagnostics {
    /// Removes what is left, every launch (nothing left is fine). The imported hot-water config
    /// beside the event file stays, and its folder is kept out of backups: the event file used
    /// to set that as a side effect, so a config imported before may not have it yet.
    public static func removeLeftovers(store: SecureStore, applicationSupport: URL, temporary: URL,
                                       fileManager: FileManager = .default) {
        let water = ShowerImportFolder.url(in: applicationSupport)
        let scanNote = applicationSupport.appendingPathComponent("WaterSession", isDirectory: true)
            .appendingPathComponent("last-scan.json")
        for url in [water.appendingPathComponent("diagnostics.json"), exportFolder(in: temporary), scanNote]
            where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        try? store.delete(.sharedCredentialLog)
        if fileManager.fileExists(atPath: water.path) { try? ShowerImportFolder.excludeFromBackup(water) }
    }

    /// Where an export put its report (reset deletes it too).
    public static func exportFolder(in temporary: URL) -> URL {
        temporary.appendingPathComponent("WaterDiagnostics", isDirectory: true)
    }
}

/// `Application Support/Water/`, where an imported `.waterconfig` is written. It holds the
/// platform secret, so it is kept out of backups.
public enum ShowerImportFolder {
    public static func url(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Water", isDirectory: true)
    }

    /// Creates the folder of `file` and keeps it out of backups, before the file is written.
    public static func prepare(for file: URL, fileManager: FileManager = .default) throws {
        let folder = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try excludeFromBackup(folder)
    }

    static func excludeFromBackup(_ folder: URL) throws {
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
