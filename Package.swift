// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Aureole",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Aureole", targets: ["Aureole"]),
        .library(name: "AureoleCore", targets: ["AureoleCore"]),
    ],
    targets: [
        .target(name: "AureoleCore", path: "Sources/AureoleCore"),
        .executableTarget(name: "Aureole", dependencies: ["AureoleCore"], path: "Sources/Aureole"),
        .testTarget(name: "AureoleCoreTests", dependencies: ["AureoleCore"],
                    path: "Tests/AureoleCoreTests", resources: [.copy("Fixtures")]),
    ]
)
