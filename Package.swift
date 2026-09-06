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
        )
    ]
)
