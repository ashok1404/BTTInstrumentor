// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BTTInstrumentor",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "BTTInstrumentor", targets: ["BTTInstrumentor"])
    ],
    targets: [
        .executableTarget(
            name: "BTTInstrumentor",
            path: "Sources/BTTInstrumentor"
        )
    ]
)
