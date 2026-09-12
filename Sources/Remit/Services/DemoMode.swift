import AppKit
import SwiftUI

/// `Remit --demo 1`: the app on made-up data, for screenshots and for trying Remit without a
/// Reminders account. Nothing is read from or written to EventKit, Reminders' store, Remit's own
/// settings file or its display preferences -- see `scripts/screenshots.sh` for how it is used.
///
/// Every option takes a value, flags included -- `--demo 1`, `--demo-tour 1`. AppKit reads launch
/// arguments as name/value pairs, so a bare flag shifts every argument after it by one; the word
/// left over is taken for a document to open, and a launch that opens documents opens no window.
///
/// Options, all optional except `--demo 1`:
/// - `--demo-view today|upcoming|inbox|tags|project:<title>|tag:<name>|filter:<name>`
/// - `--demo-layout list|board|calendar`, `--demo-range day|threeDays|week|month`,
///   `--demo-group default|none|dueDate|priority|label|project`
/// - `--demo-quick-add <text>` opens quick add with that text typed
/// - `--demo-peek <task title>` opens that task's details
/// - `--demo-tour 1` opens the welcome tour
/// - `--size <width>x<height>` window content size in points, default 1280x800
/// - `--snapshot <path>` writes the window, and any sheet on it, to a PNG and quits
/// - `--demo-log <path>` appends progress to a file
enum DemoMode {
    static let isActive = CommandLine.arguments.contains("--demo")

    static let data: DemoData? = isActive ? DemoData.sample() : nil

    /// Posted just before a snapshot. ContentView answers by nudging its opacity, which makes SwiftUI
    /// redraw every view -- the only thing, besides a sheet opening, that got the sidebar to draw
    /// into the window's cached image.
    static let redrawNotification = Notification.Name("RemitDemoRedraw")

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Where the app opens. Always Today outside demo mode.
    static var initialSelection: SidebarSelection {
        guard isActive, let raw = value(after: "--demo-view") else { return .today }
        switch raw {
        case "today": return .today
        case "upcoming": return .upcoming
        case "inbox": return .inbox
        case "tags": return .filtersAndLabels
        default:
            if raw.hasPrefix("project:"), let project = data?.project(titled: String(raw.dropFirst("project:".count))) {
                return .project(project.id)
            }
            if raw.hasPrefix("tag:") {
                return .label(String(raw.dropFirst("tag:".count)))
            }
            if raw.hasPrefix("filter:"),
               let filter = data?.filters.first(where: { $0.name == String(raw.dropFirst("filter:".count)) }) {
                return .filter(filter.id)
            }
            return .today
        }
    }

    static var displayPreferences: [String: DisplayPreferences] {
        var preferences = DisplayPreferences()
        if let layout = value(after: "--demo-layout").flatMap(TaskLayout.init(rawValue:)) {
            preferences.layout = layout
        }
        if let range = value(after: "--demo-range").flatMap(CalendarRange.init(rawValue:)) {
            preferences.calendarRange = range
        }
        if let groupBy = value(after: "--demo-group").flatMap(TaskGroupBy.init(rawValue:)) {
            preferences.groupBy = groupBy
        }
        return [initialSelection.displayKey: preferences]
    }

    /// A launch that will save its window and quit.
    static var isSnapshot: Bool { isActive && value(after: "--snapshot") != nil }

    /// True for snapshot launches, which draw a plain sidebar because the glass one can't be captured.
    static var flattensSidebar: Bool { isSnapshot }

    static var quickAddText: String? { isActive ? value(after: "--demo-quick-add") : nil }
    static var peekTitle: String? { isActive ? value(after: "--demo-peek") : nil }
    static var showsTour: Bool { isActive && CommandLine.arguments.contains("--demo-tour") }

    /// A throwaway folder for the demo's metadata, so saved filters and favourites never touch the
    /// real `metadata.json`.
    private static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RemitDemo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    @MainActor
    static func makeMetadataStore(for data: DemoData) -> MetadataStore {
        let store = MetadataStore(directory: scratchDirectory)
        for filter in data.filters {
            store.addFilter(filter)
        }
        for projectID in data.favoriteProjectIDs {
            store.toggleFavorite(projectID)
        }
        return store
    }

    private static var windowSize: CGSize {
        let fallback = CGSize(width: 1280, height: 800)
        guard let raw = value(after: "--size") else { return fallback }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : fallback
    }

    /// Logs that SwiftUI drew the main content. The sizing and snapshot sequence doesn't wait for
    /// this -- it starts at launch -- because a window opened in the background can be created
    /// without its content ever appearing until it is brought forward.
    @MainActor
    static func windowAppeared() {
        guard isActive else { return }
        log("content appeared")
    }

    @MainActor
    private static var didStart = false

    /// The demo sequence: bring the app forward, find (or open) the main window, size it, and with
    /// `--snapshot` save it and quit. Started from app launch.
    @MainActor
    private static func run() async {
        guard !didStart else { return }
        didStart = true
        // Screenshots in one appearance, whatever the Mac is set to.
        NSApp.appearance = NSAppearance(named: .aqua)
        let snapshotPath = value(after: "--snapshot")

        var window: NSWindow?
        for attempt in 0..<40 {
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            window = NSApp.windows.first { !$0.isSheet && $0.canBecomeMain && $0.frame.width > 300 }
            if window != nil { break }
            if attempt == 10 {
                log("no window yet; active=\(NSApp.isActive) windows=\(describeWindows())")
                // A WindowGroup opens its first window at launch; if that was skipped, ask for one.
                NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            }
        }
        guard let window else {
            log("no main window after 6s; active=\(NSApp.isActive) windows=\(describeWindows())")
            if snapshotPath != nil { NSApp.terminate(nil) }
            return
        }
        window.setContentSize(windowSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        log("window ready: \(describe(window)); active=\(NSApp.isActive)")

        guard let snapshotPath else { return }
        // Long enough for content to appear, sheets to finish animating in and lists to lay out.
        try? await Task.sleep(for: .milliseconds(2500))
        collapseTextSelection(in: window)
        if let sheet = window.attachedSheet { collapseTextSelection(in: sheet) }
        NotificationCenter.default.post(name: redrawNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(600))
        do {
            try snapshot(to: URL(fileURLWithPath: snapshotPath))
            log("snapshot written: \(snapshotPath)")
        } catch {
            log("snapshot failed: \(error); windows=\(describeWindows())")
        }
        NSApp.terminate(nil)
    }

    /// A field that takes focus selects all its text, which reads as a highlight in a screenshot.
    @MainActor
    private static func collapseTextSelection(in window: NSWindow) {
        guard let editor = window.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    @MainActor
    private static func describe(_ window: NSWindow) -> String {
        "\(window.className) visible=\(window.isVisible) \(Int(window.frame.width))x\(Int(window.frame.height))"
    }

    @MainActor
    private static func describeWindows() -> String {
        NSApp.windows.map(describe).joined(separator: ", ")
    }

    /// Demo launches are driven by a script. An app started through `open` has nowhere visible for
    /// stderr to go, so `--demo-log <path>` appends progress to a file as well.
    private static func log(_ message: String) {
        let line = Data("[Remit demo] \(message)\n".utf8)
        FileHandle.standardError.write(line)
        guard let path = value(after: "--demo-log") else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        }
    }

    /// Called from app launch, before any view exists, so a log shows whether SwiftUI got as far as
    /// drawing anything at all.
    @MainActor
    static func launched() {
        guard isActive else { return }
        log("launched with \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        Task { @MainActor in await run() }
    }

    @MainActor
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { !$0.isSheet && $0.canBecomeMain && $0.frame.width > 300 }
    }

    private enum SnapshotError: Error {
        case noWindow, noImage
    }

    /// Draws the window's frame view -- title bar and toolbar included -- and any attached sheet at
    /// its on-screen position, at the display's pixel density, framed with rounded corners and a soft
    /// shadow on a transparent margin so the image sits well on light and dark pages alike. Drawing
    /// Remit's own views needs no screen-recording permission.
    @MainActor
    private static func snapshot(to url: URL) throws {
        guard let window = mainWindow, let frameView = window.contentView?.superview else {
            throw SnapshotError.noWindow
        }
        let margin: CGFloat = 40
        let windowSize = window.frame.size
        let size = CGSize(width: windowSize.width + margin * 2, height: windowSize.height + margin * 2)
        let scale = window.backingScaleFactor
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw SnapshotError.noImage }
        canvas.size = size

        let windowRect = CGRect(origin: CGPoint(x: margin, y: margin), size: windowSize)
        let outline = NSBezierPath(roundedRect: windowRect, xRadius: 12, yRadius: 12)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

        // Shadow, cast by a filled shape so the window's own transparent edges can't show through.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        NSColor(Theme.pageBackground).setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        draw(frameView, at: windowRect.origin)
        if let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview {
            draw(sheetView, at: CGPoint(x: margin + sheet.frame.minX - window.frame.minX,
                                        y: margin + sheet.frame.minY - window.frame.minY))
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.12).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = canvas.representation(using: .png, properties: [:]) else { throw SnapshotError.noImage }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    @MainActor
    private static func draw(_ view: NSView, at origin: CGPoint) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        rep.draw(in: CGRect(origin: origin, size: view.bounds.size))
    }
}
