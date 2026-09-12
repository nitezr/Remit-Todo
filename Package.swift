// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Remit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Remit", targets: ["Remit"]),
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
        // Apple Reminders' own tags, sections and groups, read straight from its store. Its own
        // module so the reader is tested against a fixture store without building the app.
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
