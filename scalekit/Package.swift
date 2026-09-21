// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScaleKit",
    products: [
        .library(name: "ScaleKit", targets: ["ScaleKit"]),
        .executable(name: "a6host", targets: ["A6Host"]),
    ],
    targets: [
        .target(name: "ScaleKit"),
        .executableTarget(
            name: "A6Host",
            dependencies: ["ScaleKit"],
            path: "Sources/A6Host"
        ),
        .testTarget(name: "ScaleKitTests", dependencies: ["ScaleKit"],
                    resources: [.copy("golden_vectors.json"), .copy("synthetic_session_capture.json")])
    ]
)
