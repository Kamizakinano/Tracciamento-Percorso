import Foundation

/// Backup automatico dei viaggi in una cartella scelta dall'utente (per esempio
/// in iCloud Drive). Usa un segnalibro di sicurezza, quindi non servono
/// permessi iCloud particolari: funziona anche con un Apple ID gratuito.
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    static let fileName = "Percorso-backup.json"
    private let bookmarkKey = "backupBookmark"
    private let lastBackupKey = "lastBackup"

    @Published private(set) var folderName: String?
    @Published private(set) var lastBackup: Date?
    @Published private(set) var lastError: String?

    private var pending: DispatchWorkItem?

    private init() {
        lastBackup = UserDefaults.standard.object(forKey: lastBackupKey) as? Date
        folderName = resolveFolder()?.lastPathComponent
    }

    var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// Imposta la cartella di backup (URL ottenuto dal selettore di cartelle).
    func setFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            folderName = url.lastPathComponent
            lastError = nil
        } catch {
            lastError = "Cartella non utilizzabile: \(error.localizedDescription)"
        }
    }

    func removeFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        folderName = nil
    }

    /// Esegue il backup poco dopo l'ultima modifica (più modifiche ravvicinate = un solo backup).
    func scheduleBackup(_ trips: [Trip]) {
        guard isConfigured else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.backup(trips) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    @discardableResult
    func backup(_ trips: [Trip]) -> Bool {
        guard let folder = resolveFolder() else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let target = folder.appendingPathComponent(Self.fileName)
        var failure: Error?
        do {
            let data = try JSONEncoder().encode(trips)
            var coordError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { url in
                do { try data.write(to: url, options: .atomic) } catch { failure = error }
            }
            failure = failure ?? coordError
        } catch {
            failure = error
        }
        if let failure {
            lastError = "Backup non riuscito: \(failure.localizedDescription)"
            return false
        }
        lastBackup = Date()
        lastError = nil
        UserDefaults.standard.set(lastBackup, forKey: lastBackupKey)
        return true
    }

    /// Legge i viaggi da un file di backup scelto dall'utente.
    static func readBackup(at url: URL) throws -> [Trip] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try JSONDecoder().decode([Trip].self, from: result.get())
    }

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }
}
