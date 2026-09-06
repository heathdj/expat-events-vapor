// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExpatEventsAPI",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "ExpatEventsAPI", targets: ["ExpatEventsAPI"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ExpatEventsAPI",
            dependencies: []
        ),
        .testTarget(
            name: "ExpatEventsAPITests",
            dependencies: ["ExpatEventsAPI"]
        )
    ]
)
