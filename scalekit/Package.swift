// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScaleKit",
    products: [
        .library(name: "ScaleKit", targets: ["ScaleKit"])
    ],
    targets: [
        .target(name: "ScaleKit"),
        .testTarget(name: "ScaleKitTests", dependencies: ["ScaleKit"],
                    resources: [.copy("golden_vectors.json"), .copy("synthetic_session_capture.json")])
    ]
)
