// swift-tools-version:5.9
import PackageDescription

// Everything in Stow that is plain logic: request building, response parsing, retry
// timing, history. No SwiftUI, AVFoundation or UIKit, so it builds and tests anywhere
// Swift runs, including Linux, where the app target cannot.
let package = Package(
    name: "StowCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "StowCore", targets: ["StowCore"])
    ],
    targets: [
        .target(name: "StowCore"),
        .testTarget(name: "StowCoreTests", dependencies: ["StowCore"])
    ]
)
