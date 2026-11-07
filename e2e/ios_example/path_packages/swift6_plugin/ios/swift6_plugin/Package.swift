// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift6_plugin",
    platforms: [.iOS("13.0")],
    products: [.library(name: "swift6-plugin", targets: ["swift6_plugin"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .target(
            name: "swift6_plugin",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")]
        ),
    ]
)
