import Foundation

/// Tells Remit when Reminders' store changes underneath it.
///
/// EventKit's change notification covers what EventKit models. A tag or section edited in
/// Reminders.app, or synced in from iPhone, is not guaranteed to raise it, and without this such an
/// edit would only appear after some unrelated refresh. Every write to the store lands in its SQLite
/// files, so watching those catches all of them. Needs the same Full Disk Access as reading does.
final class StoreWatcher {
    private let directory: URL
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onChange = onChange
        arm()
    }

    deinit {
        pending?.cancel()
        sources.forEach { $0.cancel() }
    }

    private func arm() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }

        for name in names where name.hasPrefix("Data-") && (name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal")) {
            let descriptor = open(directory.appendingPathComponent(name).path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // A checkpoint can replace the log file outright; re-arm so the watch follows it.
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
                }
                self.scheduleChange()
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    /// Reminders writes in bursts -- one sync touches the files many times a second -- so changes are
    /// coalesced into a single callback.
    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
