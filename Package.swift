// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Remit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Remit", targets: ["Remit"]),
        // Separate binary on purpose: agent/automation access must not put a request loop inside
        // the UI process. See Sources/remit-cli/main.swift.
        //
        // Named "remit-cli", NOT "remit": macOS filesystems are case-insensitive by default, so a
        // product called "remit" and the app's "Remit" resolve to the same path in .build/debug and
        // silently overwrite each other -- which packaged the CLI binary inside Remit.app.
        .executable(name: "remit-cli", targets: ["remit-cli"]),
    ],
    targets: [
        .executableTarget(
            name: "Remit",
            dependencies: ["ReminderKitBridge", "RemindersNative"],
            path: "Sources/Remit",
            exclude: ["Supporting/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Remit/Supporting/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "remit-cli",
            dependencies: ["RemindersNative"],
            path: "Sources/remit-cli",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/remit-cli/Info.plist"
                ])
            ]
        ),
        // Apple Reminders' own tags, sections and groups, read straight from its store. A library
        // rather than part of the app so remit-cli reports the same tags the app shows.
        .target(
            name: "RemindersNative",
            path: "Sources/RemindersNative"
        ),
        // Writes for the same metadata, through the private ReminderKit framework. Objective-C
        // because ReminderKit has no Swift interface and its exceptions must be caught in-language.
        .target(
            name: "ReminderKitBridge",
            path: "Sources/ReminderKitBridge",
            publicHeadersPath: "include"
        ),
        // Tests link against the app target so the persistence layer is covered by the same code
        // the app actually ships, not a copy of it.
        .testTarget(
            name: "RemitTests",
            dependencies: ["Remit", "RemindersNative"],
            path: "Tests/RemitTests"
        )
    ]
)
