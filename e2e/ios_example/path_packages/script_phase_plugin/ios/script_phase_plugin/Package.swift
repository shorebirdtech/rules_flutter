// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "script_phase_plugin",
    platforms: [.iOS("13.0")],
    products: [.library(name: "script-phase-plugin", targets: ["script_phase_plugin"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .target(
            name: "script_phase_plugin",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")]
        ),
    ]
)
