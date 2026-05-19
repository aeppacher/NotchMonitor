// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NotchMonitor", targets: ["NotchMonitor"]),
    ],
    targets: [
        .executableTarget(
            name: "NotchMonitor",
            path: "Sources/NotchMonitor"
        ),
    ]
)
