"""The target a user names for a Flutter iOS or macOS app.

`ios_application` and `macos_application` change the platform of their own
configuration (to iOS, to macOS), and a target is checked against
`target_compatible_with` in the configuration it is built in. So the
constraints a user puts on the app, or the macro puts on it for the platforms
it is for, are never seen as they were written on the rules_apple target: an
iOS platform has no `@platforms//os:macos` to satisfy, and on a Linux build
the rule is analysed (and fails) before anything compares the platforms.

A target in front of the rules_apple one does not change the platform. It
carries the constraints, so `bazel build //...` on a platform the app is not
for reports it SKIPPED, and forwards what the rules_apple target provides.
"""

load(
    "@rules_apple//apple:providers.bzl",
    "AppleBundleInfo",
    "AppleDebugOutputsInfo",
    "AppleDsymBundleInfo",
    "AppleExecutableBinaryInfo",
    "IosApplicationBundleInfo",
    "MacosApplicationBundleInfo",
)

# What a rules_apple application provides that something downstream reads: a
# test host takes the bundle info, `bazel run` the executable, and a dSYM
# build the debug outputs.
_FORWARDED = [
    AppleBundleInfo,
    AppleDebugOutputsInfo,
    AppleDsymBundleInfo,
    AppleExecutableBinaryInfo,
    IosApplicationBundleInfo,
    MacosApplicationBundleInfo,
    OutputGroupInfo,
    InstrumentedFilesInfo,
]

def _impl(ctx):
    app = ctx.attr.app
    archive = app[AppleBundleInfo].archive

    # The archive is named after the rules_apple target, which is private.
    # The one a user asked for is named after this one, as it always was.
    link = ctx.actions.declare_file(ctx.label.name + "." + archive.extension)
    ctx.actions.symlink(output = link, target_file = archive)

    executable = ctx.outputs.executable
    ctx.actions.symlink(
        output = executable,
        target_file = app[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    return [
        DefaultInfo(
            executable = executable,
            files = depset([link] + [f for f in app[DefaultInfo].files.to_list() if f != archive]),
            runfiles = app[DefaultInfo].default_runfiles.merge(ctx.runfiles(files = [link])),
        ),
    ] + [app[provider] for provider in _FORWARDED if provider in app]

flutter_apple_app = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(
            doc = "The rules_apple application. Not built for this target's platform: it sets its own.",
            mandatory = True,
            providers = [AppleBundleInfo],
        ),
    },
    executable = True,
    doc = """The Flutter app a user names: carries `target_compatible_with` in front of a rules_apple application.

Forwards the application's providers and executable, and its archive under this
target's name (`<name>.ipa`, `<name>.zip`).""",
)
