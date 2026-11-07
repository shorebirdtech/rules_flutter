"""A stand-in for a flutter/flutter checkout with a built engine, made of the official artifacts.

The release's artifacts are laid out the way a checkout and its engine out dirs
hold them (`docs/design/design_custom_engine.md`, section 7.2), with `args.gn`
files written to match, so the adapters read a tree they cannot tell from a
developer's, and the binaries in it are real and run.

With `gen_snapshot_flutter_version` set, the release gen_snapshot is that of
another Flutter release (another Dart): the mismatch the check exists to refuse.
"""

# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:artifact_urls.bzl", "engine_artifact_url", "host_artifacts_path")

# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS")

_RELEASE = "3.47.9"
_OUT = "checkout/engine/src/out/"

def _args_gn(mode, revision):
    return "\n".join([
        'target_cpu = "arm64"',
        'flutter_runtime_mode = "{}"'.format(mode),
        "flutter_prebuilt_dart_sdk = false",
        'engine_version = "{}"'.format(revision),
        'content_hash = "stock-artifacts"',
        'dart_version = "stock-artifacts"',
        "",
    ])

def _fake_checkout_impl(rctx):
    def path(label):
        return rctx.path(Label(label))

    def link(source, destination):
        rctx.symlink(source, destination)

    meta = FLUTTER_VERSIONS[_RELEASE]
    dart_sdk = path("@flutter_darwin-arm64//:dart-sdk/bin/dart").dirname.dirname
    host_tools = path("@flutter_darwin-arm64//:host-tools/icudtl.dat").dirname
    font_tools = path("@flutter_darwin-arm64//:font-subset-tools/font-subset").dirname
    kernel_debug = path("@flutter_stock_engine//kernel/debug:flutter_patched_sdk/platform_strong.dill").dirname
    kernel_release = path("@flutter_stock_engine//kernel/release:flutter_patched_sdk_product/platform_strong.dill").dirname
    dev_root = path("@flutter_dev_root_src//:bin/cache/flutter.version.json").dirname.dirname.dirname

    # The framework: packages/, what bin/internal holds, sky_engine, and the
    # version a built checkout records.
    link(dev_root.get_child("packages"), "checkout/packages")
    link(dev_root.get_child("bin").get_child("cache").get_child("pkg").get_child("sky_engine"), "checkout/engine/src/flutter/sky/packages/sky_engine")
    link(dev_root.get_child("bin").get_child("cache").get_child("flutter.version.json"), "checkout/bin/cache/flutter.version.json")
    rctx.file("checkout/bin/internal/material_fonts.version", meta.material_fonts_url.split("/")[-2] + "\n")
    rctx.file("checkout/CHECKOUT", "A stand-in for a flutter/flutter checkout.\n")

    # The release gen_snapshot, or another release's.
    release_gen = path("@flutter_darwin-arm64//:host-tools-release/gen_snapshot")
    other = rctx.attr.gen_snapshot_flutter_version
    if other:
        other_meta = FLUTTER_VERSIONS[other]
        archive = host_artifacts_path("darwin-arm64", mode = "release")
        rctx.download_and_extract(
            url = engine_artifact_url(other_meta.engine_revision, archive),
            sha256 = ARTIFACT_CHECKSUMS[other][archive],
            output = "other_dart",
        )
        release_gen = rctx.path("other_dart/gen_snapshot")
    profile_gen = path("@flutter_darwin-arm64_profile//:host-tools/gen_snapshot")

    # host_debug_arm64: the host tools, the debug platform kernel and the debug engine.
    debug = _OUT + "host_debug_arm64/"
    rctx.file(debug + "args.gn", _args_gn("debug", meta.engine_revision))
    link(dart_sdk, debug + "dart-sdk")
    for name in ["flutter_tester", "icudtl.dat", "impellerc", "shader_lib"]:
        link(host_tools.get_child(name), debug + name)
    link(font_tools.get_child("font-subset"), debug + "font-subset")
    link(font_tools.get_child("const_finder.dart.snapshot"), debug + "gen/const_finder.dart.snapshot")
    for name in ["vm_isolate_snapshot.bin", "isolate_snapshot.bin"]:
        link(host_tools.get_child(name), debug + "gen/flutter/lib/snapshot/" + name)
    link(kernel_debug, debug + "flutter_patched_sdk")

    # An out dir holds the product platform kernel under the same name.
    release = _OUT + "host_release_arm64/"
    rctx.file(release + "args.gn", _args_gn("release", meta.engine_revision))
    link(kernel_release, release + "flutter_patched_sdk")
    link(release_gen, release + "gen_snapshot_arm64")
    profile = _OUT + "host_profile_arm64/"
    rctx.file(profile + "args.gn", _args_gn("profile", meta.engine_revision))
    link(profile_gen, profile + "gen_snapshot_arm64")

    for mode, out in [("debug", debug), ("profile", profile), ("release", release)]:
        framework = path("@flutter_desktop_engine_darwin-x64_{}//:engine/FlutterMacOS.framework/Versions/A/FlutterMacOS".format(mode)).dirname.dirname.dirname
        link(framework, out + "FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework")

    rctx.file("BUILD.bazel", 'exports_files(glob(["checkout/CHECKOUT"]))\n')

fake_checkout = repository_rule(
    _fake_checkout_impl,
    doc = "The official artifacts laid out as a flutter/flutter checkout with engine out dirs.",
    attrs = {
        "gen_snapshot_flutter_version": attr.string(
            doc = "A Flutter release whose gen_snapshot replaces the release's: another Dart.",
        ),
    },
)
