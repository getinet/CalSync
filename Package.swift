// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalSync",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure sync logic: markers, reconciliation, config validation.
        // No EventKit, no AppKit, no I/O — so it is fully unit-testable.
        .target(name: "CalSyncCore"),

        // The menu bar app: EventKit adapter, scheduling, UI.
        .executableTarget(
            name: "CalSyncApp",
            dependencies: ["CalSyncCore"]
        ),

        .testTarget(
            name: "CalSyncCoreTests",
            dependencies: ["CalSyncCore"]
        ),
    ]
)
