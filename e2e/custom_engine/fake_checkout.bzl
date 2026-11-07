"""A stand-in for a flutter/flutter checkout with a built engine, made of the official artifacts.

The release's artifacts are laid out the way a checkout and its engine out dirs
hold them (`docs/design/design_custom_engine.md`, section 7.2), with `args.gn`
files written to match, so the adapters read a tree they cannot tell from a
developer's, and the binaries in it are real and run.

The iOS and Android out dirs are laid out the same way: `ios_debug_sim_arm64`
(the simulator, a one-slice `Flutter.xcframework`), `ios_profile` and `ios_release`
(devices), and `android_<mode>_arm64` and `android_<mode>_x64` (a `flutter.jar`,
and the gen_snapshot of the AOT modes in `universal/`, where a Mac build puts the
one that runs on both Mac CPUs).

With `gen_snapshot_flutter_version` set, the release gen_snapshot is that of
another Flutter release (another Dart): the mismatch the check exists to refuse.
Every platform's AOT gen_snapshot is replaced by it.
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

def _mobile_args_gn(os, mode, cpu, revision, simulator = False):
    return "\n".join([
        'target_os = "{}"'.format(os),
        'target_cpu = "{}"'.format(cpu),
        'flutter_runtime_mode = "{}"'.format(mode),
        "use_ios_simulator = {}".format("true" if simulator else "false"),
        'engine_version = "{}"'.format(revision),
        'content_hash = "stock-artifacts"',
        'dart_version = "stock-artifacts"',
        "",
    ])

# The xcframework a `ninja flutter_framework` makes of one built Flutter.framework:
# its one platform directory, and the Info.plist that names it.
def _xcframework_info(identifier, architecture, simulator):
    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>LibraryIdentifier</key>
			<string>{identifier}</string>
			<key>LibraryPath</key>
			<string>Flutter.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>{architecture}</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>{variant}
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
""".format(
        identifier = identifier,
        architecture = architecture,
        variant = "\n\t\t\t<key>SupportedPlatformVariant</key>\n\t\t\t<string>simulator</string>" if simulator else "",
    )

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

    _mobile_out_dirs(rctx, path, link, meta.engine_revision, other_gen = rctx.path("other_dart/gen_snapshot") if other else None)

    rctx.file("BUILD.bazel", 'exports_files(glob(["checkout/CHECKOUT"]))\n')

def _mobile_out_dirs(rctx, path, link, revision, other_gen):
    """The iOS and Android out dirs: the official engines, laid out as ninja leaves them."""

    # iOS. The simulator engine is the debug one, for this Mac's CPU; the devices'
    # are the profile and release ones. Each xcframework holds one platform
    # directory, as one out dir's `flutter_framework` target makes it.
    ios = {
        "debug": ("ios_debug_sim_arm64", "ios-arm64-simulator", "@flutter_stock_ios_engine//:debug/Flutter.xcframework/ios-arm64_x86_64-simulator/Flutter.framework/Flutter"),
        "profile": ("ios_profile", "ios-arm64", "@flutter_ios_engine_profile//:Flutter.xcframework/ios-arm64/Flutter.framework/Flutter"),
        "release": ("ios_release", "ios-arm64", "@flutter_stock_ios_engine//:Flutter.xcframework/ios-arm64/Flutter.framework/Flutter"),
    }
    ios_gen_snapshot = {
        "profile": "@flutter_ios_engine_profile//:gen_snapshot_arm64",
        "release": "@flutter_stock_ios_engine//:gen_snapshot_arm64",
    }
    for mode, (name, identifier, binary) in ios.items():
        out = _OUT + name + "/"
        simulator = mode == "debug"
        rctx.file(out + "args.gn", _mobile_args_gn("ios", mode, "arm64", revision, simulator))
        xcframework = out + "Flutter.xcframework/"
        link(path(binary).dirname, xcframework + identifier + "/Flutter.framework")
        rctx.file(xcframework + "Info.plist", _xcframework_info(identifier, "arm64", simulator))
        if mode != "debug":
            link(other_gen or path(ios_gen_snapshot[mode]), out + "universal/gen_snapshot_arm64")

    # Android. A `flutter.jar` for each ABI and mode, and the gen_snapshot of
    # each AOT mode that runs on this Mac.
    for arch in ["arm", "arm64", "x64"]:
        jars = {
            "debug": "@flutter_stock_android_engine_{}//:debug/flutter.jar",
            "profile": "@flutter_android_engine_{}_profile//:flutter.jar",
            "release": "@flutter_stock_android_engine_{}//:flutter.jar",
        }
        gen_snapshots = {
            "profile": "@flutter_cross_darwin-arm64_android-{}_profile//:gen_snapshot",
            "release": "@flutter_cross_darwin-arm64_android-{}//:gen_snapshot",
        }
        for mode, jar in jars.items():
            # `tools/gn` names an out dir without the CPU that is a platform's default.
            out = _OUT + "android_{}{}/".format(mode, "" if arch == "arm" else "_" + arch)
            rctx.file(out + "args.gn", _mobile_args_gn("android", mode, arch, revision))
            link(path(jar.format(arch)), out + "flutter.jar")
            if mode != "debug":
                link(other_gen or path(gen_snapshots[mode].format(arch)), out + "universal/gen_snapshot")

fake_checkout = repository_rule(
    _fake_checkout_impl,
    doc = "The official artifacts laid out as a flutter/flutter checkout with engine out dirs.",
    attrs = {
        "gen_snapshot_flutter_version": attr.string(
            doc = "A Flutter release whose gen_snapshot replaces the release's: another Dart.",
        ),
    },
)
