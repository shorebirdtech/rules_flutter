// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ffi_dynamic_plugin",
    platforms: [.iOS("13.0")],
    products: [.library(name: "ffi-dynamic-plugin", type: .dynamic, targets: ["ffi_dynamic_plugin"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .target(
            name: "ffi_dynamic_plugin",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")]
        ),
    ]
)
