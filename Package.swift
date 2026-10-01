// swift-tools-version: 6.2
import PackageDescription

// Build through scripts/bundle.sh, which assembles and signs build/Pinup.app.
let package = Package(
    name: "Pinup",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Pinup",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
