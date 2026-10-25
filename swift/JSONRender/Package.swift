// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JSONRender",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "JSONRenderSwiftUI", targets: ["JSONRenderSwiftUI"]),
        .library(name: "JSONRenderPDF", targets: ["JSONRenderPDF"]),
    ],
    targets: [
        .target(
            name: "JSONRenderSwiftUI",
            resources: [.copy("Resources/json-render-bridge.js")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "JSONRenderPDF",
            dependencies: ["JSONRenderSwiftUI"],
            resources: [.copy("Resources/helvetica-metrics.json"), .copy("Resources/hyphenation-en-us.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JSONRenderPDFTests",
            dependencies: ["JSONRenderPDF", "JSONRenderSwiftUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JSONRenderSwiftUITests",
            dependencies: ["JSONRenderSwiftUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
