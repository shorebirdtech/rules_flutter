"""Unit tests for swiftpm_dependencies.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swiftpm_dependencies.bzl", "find_unsupported_swiftpm_dependencies")

def _plain_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], find_unsupported_swiftpm_dependencies("""
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "foo",
    platforms: [.iOS("13.0")],
    products: [.library(name: "foo", targets: ["foo"])],
    dependencies: [],
    targets: [.target(name: "foo", linkerSettings: [.linkedFramework("AVFoundation")])]
)
""", "ios/foo"))
    return unittest.end(env)

plain_test = unittest.make(_plain_test_impl)

def _remote_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [
        "https://github.com/apple/swift-log",
        "https://example.com/b.git",
        "registry package scope.name",
    ], find_unsupported_swiftpm_dependencies("""
let package = Package(
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(name: "b", url: "https://example.com/b.git", .upToNextMajor(from: "2.0.0")),
        .package(id: "scope.name", from: "1.0.0"),
        // .package(url: "https://example.com/commented", from: "1.0.0"),
    ],
    targets: [.target(name: "foo", dependencies: [.product(name: "Logging", package: "swift-log")])]
)
""", "darwin/foo"))
    return unittest.end(env)

remote_test = unittest.make(_remote_test_impl)

def _local_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], find_unsupported_swiftpm_dependencies("""
    dependencies: [.package(path: "../foo_shared"), .package(name: "x", path: "Sub"), .package(path: ".")],
""", "ios/foo"))
    asserts.equals(env, ["path ../../../other", "path /abs/dir"], find_unsupported_swiftpm_dependencies("""
    dependencies: [.package(path: "../../../other"), .package(name: "x", path: "/abs/dir")],
""", "ios/foo"))
    asserts.equals(env, ["path ../../../other"], find_unsupported_swiftpm_dependencies("""
    dependencies: [.package(path: "../../../other")],
""", "ios/foo"))
    return unittest.end(env)

local_test = unittest.make(_local_test_impl)

def swiftpm_dependencies_test_suite(name):
    unittest.suite(name, plain_test, remote_test, local_test)
