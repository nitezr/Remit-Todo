// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Remit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Remit", targets: ["Remit"])
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
        )
    ]
)
