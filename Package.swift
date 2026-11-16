// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ply",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ply", targets: ["PlyCLI"]),
        .executable(name: "PlyApp", targets: ["PlyApp"]),
        .executable(name: "ply-helper", targets: ["PlyHelper"]),
        .library(name: "PlyCore", targets: ["PlyCore"]),
    ],
    targets: [
        .target(name: "PlyShared"),
        .target(
            name: "PlyCore",
            dependencies: ["PlyShared"],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(name: "PlyCLI", dependencies: ["PlyCore"]),
        .executableTarget(
            name: "PlyApp",
            dependencies: ["PlyCore"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(
            name: "PlyHelper",
            dependencies: ["PlyShared"],
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .testTarget(name: "PlyCoreTests", dependencies: ["PlyCore"]),
    ]
)
