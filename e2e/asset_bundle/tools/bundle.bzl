"""The `flutter_assets/` tree an application builds for a chosen platform."""

load("@rules_dart//dart:defs.bzl", "dart_test")
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:providers.bzl", "FlutterApplicationInfo")

def _platform_transition_impl(settings, attr):
    # The kernel is compiled in debug mode: nothing here depends on the
    # compiled program, only on what the asset step bundles, and a debug
    # build skips the AOT compile.
    return {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:platforms": [str(attr.platform)] if attr.platform else settings["//command_line_option:platforms"],
    }

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
    ],
)

def _app_bundle_impl(ctx):
    app = ctx.attr.application[0]
    return [DefaultInfo(files = depset([app[FlutterApplicationInfo].flutter_assets]))]

app_bundle = rule(
    implementation = _app_bundle_impl,
    doc = "Exposes the `flutter_assets/` tree of `application` as built for `platform`.",
    attrs = {
        "application": attr.label(
            cfg = _platform_transition,
            providers = [FlutterApplicationInfo],
            mandatory = True,
        ),
        "platform": attr.label(
            doc = "The platform to build `application` for; the build's own when unset.",
        ),
    },
)

def bundled_app(name, assets = [], deps = [], package_name = "asset_bundle", platform = None, **kwargs):
    """A trivial application and, as `<name>_bundle`, the asset tree it builds.

    What the applications of this workspace differ in is where they sit, which
    assets they declare and which libraries they depend on, never the program.

    Args:
        name: The application's name.
        assets: Its own asset files.
        deps: Libraries beside `@deps//:flutter`.
        package_name: The application's Dart package name.
        platform: The platform to build the bundle for.
        **kwargs: More attributes of the application.
    """
    flutter_application(
        name = name,
        assets = assets,
        main = "lib/main.dart",
        package_name = package_name,
        deps = ["@deps//:flutter"] + deps,
        **kwargs
    )
    app_bundle(
        name = name + "_bundle",
        application = ":" + name,
        platform = platform,
        visibility = ["//visibility:public"],
    )

def bundle_test(name, bundle, expected, prefix = "", platform = "", subdir = "", allow_extra = False, unlisted = [], **kwargs):
    """Checks the tree `bundle` builds against the assets `flutter build` would bundle.

    Args:
        name: The test's name, which states the property it checks.
        bundle: An `app_bundle` target.
        expected: A file under `//tests:expected`, in the shape
            `tests/bundle_check.dart` documents.
        prefix: Put in front of every key and path in `expected`; the
            `packages/<name>/` of a library's assets.
        platform: The `platforms:` value the bundle is built for, for the
            entries of `expected` that restrict it.
        subdir: Where the `flutter_assets/` tree sits in `bundle`, for a bundle
            that holds more than that.
        allow_extra: Whether the bundle may hold more than `expected` lists.
        unlisted: Files the bundle must hold that have no key in its manifest.
        **kwargs: More attributes of the test.
    """
    args = ["$(rlocationpath %s)" % bundle, "$(rlocationpath %s)" % expected]
    if prefix:
        args.append("--prefix=" + prefix)
    if platform:
        args.append("--platform=" + platform)
    if subdir:
        args.append("--subdir=" + subdir)
    if allow_extra:
        args.append("--allow-extra")
    args += ["--unlisted=" + f for f in unlisted]
    dart_test(
        name = name,
        args = args,
        data = [bundle, expected],
        main = "//tests:bundle_test.dart",
        size = "small",
        deps = [
            "//tests:bundle_check",
            "@rules_dart//dart/runfiles",
        ],
        **kwargs
    )

def _tree_impl(ctx):
    return [DefaultInfo(files = depset([f for f in ctx.files.src if f.is_directory]))]

tree_of = rule(
    implementation = _tree_impl,
    doc = "The directory `src` builds, without the files beside it.",
    attrs = {"src": attr.label(mandatory = True)},
)
