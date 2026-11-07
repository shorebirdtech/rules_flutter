// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "resource_plugin",
    platforms: [.iOS("13.0")],
    products: [.library(name: "resource-plugin", targets: ["resource_plugin"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .target(
            name: "resource_plugin",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")],
            resources: [.process("Resources")]
        ),
    ]
)
