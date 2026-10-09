import Foundation

/// Remembers each sound file's LoudnessAnalyzer measurement, persisted to disk, so a file is only
/// decoded and analyzed once rather than on every launch — imported files get a unique UUID file
/// name (see PlaylistStore.copySounds) and are never modified, so the file name is a stable key.
///
/// Measurements (not gains) are stored, so changing the normalization target later doesn't require
/// re-analyzing anything. Accessed from both the main thread and the background analysis queue.
final class LoudnessCache {
    private let fileURL: URL?
    private let lock = NSLock()
    private var measurements: [String: LoudnessAnalyzer.Measurement]
    private var saveWorkItem: DispatchWorkItem?

    /// `fileURL` nil keeps the cache in memory only (e.g. for tests).
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: LoudnessAnalyzer.Measurement].self, from: data) {
            measurements = decoded
        } else {
            measurements = [:]
        }
    }

    func measurement(for audioFileURL: URL) -> LoudnessAnalyzer.Measurement? {
        lock.lock()
        defer { lock.unlock() }
        return measurements[audioFileURL.lastPathComponent]
    }

    /// Returns the cached measurement, analyzing (and caching) the file first if needed.
    func measurementAnalyzingIfNeeded(for audioFileURL: URL) -> LoudnessAnalyzer.Measurement? {
        if let cached = measurement(for: audioFileURL) { return cached }
        guard let measured = LoudnessAnalyzer.measure(fileURL: audioFileURL) else { return nil }
        lock.lock()
        measurements[audioFileURL.lastPathComponent] = measured
        lock.unlock()
        scheduleSave()
        return measured
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.writeToDisk() }
            self.saveWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
        }
    }

    private func writeToDisk() {
        guard let fileURL else { return }
        lock.lock()
        let snapshot = measurements
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
