// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Overlay",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Overlay",
            dependencies: [
                .product(name: "Textual", package: "textual"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources",
            swiftSettings: [
                // The app predates Swift 6 strict concurrency; keep v5
                // semantics until it's audited.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
