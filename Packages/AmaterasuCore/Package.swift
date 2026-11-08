// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmaterasuCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Mock", targets: ["Mock"]),
        .library(name: "NotchLayout", targets: ["NotchLayout"]),
        .library(name: "SeratoDatabase", targets: ["SeratoDatabase"]),
        .executable(name: "serato-probe", targets: ["SeratoProbe"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Mock", dependencies: ["Domain"]),
        .target(name: "NotchLayout"),
        .target(name: "SeratoDatabase", dependencies: ["Domain"]),
        .executableTarget(name: "SeratoProbe", dependencies: ["SeratoDatabase", "Domain"]),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "NotchLayoutTests", dependencies: ["NotchLayout"]),
        .testTarget(name: "SeratoDatabaseTests", dependencies: ["SeratoDatabase", "Domain"]),
    ]
)
