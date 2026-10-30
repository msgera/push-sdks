// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MsgeraPush",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "MsgeraPush", targets: ["MsgeraPush"]),
        .library(name: "MsgeraPushExtension", targets: ["MsgeraPushExtension"]),
    ],
    targets: [
        .target(name: "MsgeraPush", path: "ios/Sources/MsgeraPush"),
        .target(name: "MsgeraPushExtension", path: "ios/Sources/MsgeraPushExtension"),
    ]
)
