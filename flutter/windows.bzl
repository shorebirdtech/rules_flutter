"""Flutter rules for Windows desktop builds.

Two tiers of API:

    Tier 1 — flutter_windows_app (self-contained, recommended):

        load("@rules_flutter//flutter:windows.bzl", "flutter_windows_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_windows_app(
            name = "my_windows_app",
            application = ":my_app",
        )

    Prerequisites: run `flutter create --platforms=windows .` to generate
    the conventional `windows/runner/` directory with C++ runner files.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:windows.bzl",
            "flutter_windows_bundle",
            "flutter_windows_engine",
            "flutter_windows_registrant_gen",
            "flutter_windows_resources",
            "flutter_windows_runner_lib_gen")

        flutter_windows_engine(name = "flutter_engine")
        flutter_windows_registrant_gen(name = "app_registrant", application = ":my_app")

        flutter_windows_resources(
            name = "my_resources",
            rc = "windows/runner/Runner.rc",
            srcs = glob(["windows/runner/*.h", "windows/runner/resources/**"]),
            build_name = "1.2.3",
            build_number = "4",
        )

        flutter_windows_runner_lib_gen(
            name = "my_runner",
            engine = ":flutter_engine",
            registrant = ":app_registrant",
            srcs = glob(["windows/runner/*.cpp"]),
            hdrs = glob(["windows/runner/*.h"]),
            resources = [":my_resources"],
            manifest = "windows/runner/runner.exe.manifest",
        )

        flutter_windows_bundle(
            name = "my_windows_app",
            application = ":my_app",
            runner = ":my_runner",
        )

Output directory structure:
    my_app/
      my_app.exe             (Win32 runner executable)
      flutter_windows.dll    (Flutter engine)
      *.dll                  (native plugin libraries, if any)
      data/
        app.so               (AOT-compiled Dart code as ELF)
        flutter_assets/      (fonts, images, shaders, asset manifest)
        icudtl.dat           (ICU internationalization data)

Cross-compilation (debug only): build from macOS/Linux for Windows with:
    bazel build //target -c dbg --platforms=@rules_flutter//flutter/platforms:windows_x64
A Windows resource compiler (llvm-rc, say) must then be registered for
@bazel_tools//tools/res:toolchain_type: on a Windows host Bazel registers the
Windows SDK's rc.exe, elsewhere nothing does (see flutter_windows_resources).
"""

load("//flutter/private:app_version.bzl", "version_arg")
load("//flutter/private:flutter_windows_application.bzl", _flutter_windows_bundle_rule = "flutter_windows_bundle_rule", _flutter_windows_runner_lib = "flutter_windows_runner_lib")
load("//flutter/private:flutter_windows_engine_rule.bzl", _flutter_windows_engine_rule = "flutter_windows_engine_rule")
load("//flutter/private:flutter_windows_plugin_library.bzl", _flutter_windows_plugin_library = "flutter_windows_plugin_library")
load("//flutter/private:flutter_windows_registrant.bzl", _flutter_windows_registrant = "flutter_windows_registrant")
load("//flutter/private:flutter_windows_resources.bzl", _flutter_windows_resources = "flutter_windows_resources")

# -- Composable rules (Tier 2) ------------------------------------------------

flutter_windows_engine = _flutter_windows_engine_rule
flutter_windows_registrant_gen = _flutter_windows_registrant

# Compiles a runner's resource script (`Runner.rc`: icon, version information)
# with the registered Windows resource compiler, for
# `flutter_windows_runner_lib_gen`'s `resources` or a `cc_binary`'s `deps`.
flutter_windows_resources = _flutter_windows_resources

# Public wrapper that bundles a Flutter plugin's Windows C++ sources for the
# runner to compile + link. For pub.dev plugins, flutter_pub_package emits
# this automatically; expose it here so users can wire a monorepo plugin's
# BUILD.bazel without going through the flutter/ext/ overlay system.
flutter_windows_plugin_library = _flutter_windows_plugin_library

def flutter_windows_runner_lib_gen(name, engine, registrant, application = None, srcs = [], hdrs = [], resources = [], manifest = None, **kwargs):
    """Compiles a Win32 runner binary from template or custom sources.

    Links against flutter_windows.dll via its import library and compiles
    the C++ client wrapper sources from the engine.

    When `application` is set, every transitive plugin's Windows C++
    sources (collected from `FlutterInfo.windows_plugin_libraries`) are
    compiled alongside the runner so the registrant's
    `<Plugin>RegisterWithRegistrar` symbols resolve at link time.

    Args:
        name: Target name (produces an executable).
        engine: A flutter_windows_engine target.
        registrant: A flutter_windows_registrant_gen target.
        application: A flutter_application target. Required to wire pub
            plugins' Windows C++ sources into the runner; optional only
            for legacy Tier-2 setups with no native plugins.
        srcs: Custom C++ sources (empty = use built-in template).
        hdrs: Custom C++ headers.
        resources: `flutter_windows_resources` targets to link: the icon
            and version information.
        manifest: An application manifest to embed (`runner.exe.manifest`).
        **kwargs: Additional arguments (e.g. build_name, build_number, tags,
            visibility).
    """
    _flutter_windows_runner_lib(
        name = name,
        engine = engine,
        registrant = registrant,
        application = application,
        srcs = srcs if srcs else [],
        hdrs = hdrs if hdrs else [],
        resources = resources,
        manifest = manifest,
        **kwargs
    )

def flutter_windows_bundle(name, application, runner, **kwargs):
    """Assembles a Windows application directory from a runner and application.

    This is the public assembler rule — equivalent to macos_application
    (rules_apple) or android_binary (rules_android). Takes a pre-compiled
    runner executable and FlutterApplicationInfo, produces the bundle directory.

    Args:
        name: Target name.
        application: A flutter_application target (FlutterApplicationInfo).
        runner: A pre-compiled runner executable (from flutter_windows_runner_lib_gen or cc_binary).
        **kwargs: Additional arguments (e.g. app_name, tags, visibility).
    """
    _flutter_windows_bundle_rule(
        name = name,
        application = application,
        runner = runner,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_windows_app(
        name,
        application,
        app_name = None,
        build_name = None,
        build_number = None,
        **kwargs):
    """Builds a Flutter Windows application directory from a flutter_application target.

    Discovers runner files from the conventional `windows/runner/` directory
    (as generated by `flutter create --platforms=windows .`) and wires up all
    internal targets automatically.

    If no `windows/runner/` directory exists, falls back to the built-in
    runner template from rules_flutter.

    The runner's `Runner.rc` (icon, version information) is compiled with the
    Windows resource compiler registered for the build and linked into the
    executable, and its `runner.exe.manifest` embedded, as `flutter build
    windows` does. The build fails if no resource compiler is registered.

    Args:
        name: Target name (Bazel identifier).
        application: A flutter_application target (required).
        app_name: Bundle/binary name (defaults to target name).
        build_name: The version, `MAJOR.MINOR.PATCH`, as `flutter build
            --build-name` takes it. The executable's version information
            carries it. Defaults to `1.0.0`. May be a `select()`.
            Unset, the `application`'s `build_name`. Set, the
            `application` must set the same.
            `--@rules_flutter//flutter:build_name` replaces both for one build.
        build_number: The build number, as `flutter build --build-number`
            takes it: the fourth of the executable's version numbers.
            Defaults to `1`. May be a `select()`.
            Unset, the `application`'s `build_number`. Set, the
            `application` must set the same.
            `--@rules_flutter//flutter:build_number` replaces both for one build.
        **kwargs: Passed through to flutter_windows_bundle, except `testonly`,
            which every target the macro declares has, since one that depends on a
            `testonly` application would otherwise fail analysis.
    """
    tags = kwargs.pop("tags", [])
    target_compatible_with = kwargs.pop("target_compatible_with", None)
    testonly = kwargs.pop("testonly", False)

    # Attributes propagated to all intermediate targets so that
    # `target_compatible_with` (and tags) cause Bazel to skip analysis on
    # incompatible platforms (e.g. building Windows targets on macOS), and
    # `testonly`, which a target that depends on a `testonly` application has to
    # have too.
    common = {"tags": tags, "testonly": testonly}
    if target_compatible_with:
        common["target_compatible_with"] = target_compatible_with

    # 1. Engine target.
    _flutter_windows_engine_rule(
        name = "__%s_engine" % name,
        **common
    )

    # 2. Registrant target.
    #    If flutter create registrant files exist, use them directly (they match
    #    the #include "flutter/generated_plugin_registrant.h" path expected by
    #    flutter create runner code). Otherwise, generate from FlutterInfo.
    # `allow_empty`: the files exist only where `flutter create` or
    # `flutter pub get` wrote them; the fallback generates the registrant.
    flutter_create_registrant = native.glob(
        [
            "windows/flutter/generated_plugin_registrant.cc",
            "windows/flutter/generated_plugin_registrant.h",
        ],
        allow_empty = True,
    )
    if flutter_create_registrant:
        native.filegroup(
            name = "__%s_registrant" % name,
            srcs = flutter_create_registrant,
            **common
        )
    else:
        _flutter_windows_registrant(
            name = "__%s_registrant" % name,
            application = application,
            **common
        )

    # 3. Runner target — discover flutter create output or use template.
    # `allow_empty`: an app without a runner directory gets the template's.
    runner_srcs = native.glob(["windows/runner/*.cc", "windows/runner/*.cpp"], allow_empty = True)
    runner_hdrs = native.glob(["windows/runner/*.h"], allow_empty = True)

    # The resource script and manifest the runner's CMakeLists.txt lists:
    # from `windows/runner/` when the app has its own runner (a runner without
    # them links without them, as its CMake build would), the built-in
    # runner's otherwise.
    version = {
        "build_name": version_arg(build_name),
        "build_number": version_arg(build_number),
    }
    if runner_srcs:
        rc = native.glob(["windows/runner/Runner.rc"], allow_empty = True)
        rc_srcs = runner_hdrs + native.glob(["windows/runner/resources/**"], allow_empty = True)
        rc_defines = []
        manifests = native.glob(["windows/runner/runner.exe.manifest"], allow_empty = True)
        manifest = manifests[0] if manifests else None
    else:
        rc = [Label("//flutter/private/runners:windows/Runner.rc")]
        rc_srcs = [Label("//flutter/private/runners:windows_runner_resource_srcs")]
        rc_defines = ["RUNNER_APP_NAME=\"%s\"" % (app_name or name)]
        manifest = Label("//flutter/private/runners:windows/runner.exe.manifest")
    resources = []
    if rc:
        _flutter_windows_resources(
            name = "__%s_resources" % name,
            rc = rc[0],
            srcs = rc_srcs,
            application = application,
            defines = rc_defines,
            **(common | version)
        )
        resources = ["__%s_resources" % name]

    _flutter_windows_runner_lib(
        name = "__%s_runner" % name,
        engine = "__%s_engine" % name,
        registrant = "__%s_registrant" % name,
        application = application,
        srcs = runner_srcs if runner_srcs else [],
        hdrs = runner_hdrs if runner_hdrs else [],
        resources = resources,
        manifest = manifest,
        app_name = None if runner_srcs else (app_name or name),
        **(common | version)
    )

    # 4. Bundle assembly.
    _flutter_windows_bundle_rule(
        name = name,
        application = application,
        runner = "__%s_runner" % name,
        app_name = app_name or None,
        **dict(common, **kwargs)
    )
