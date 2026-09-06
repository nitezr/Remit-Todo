import Foundation

/// Temporary file tracing for diagnosing input issues. The app is launched via `open`, which
/// detaches stdout, so stderr logging is invisible -- this writes somewhere readable instead.
/// Remove once the input layer is confirmed stable.
enum RemitLog {
    private static let url = URL(fileURLWithPath: "/tmp/remit-debug.log")

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = "[\(Date().formatted(.dateTime.hour().minute().second()))] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}
