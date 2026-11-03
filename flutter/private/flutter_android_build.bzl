"""Builds targets for given Android platforms, whatever the command line asked for."""

# rules_android reads the platforms of an APK from this Starlark flag when it
# has a value, and from Bazel's native `--android_platforms` only when it is
# empty. Setting the Starlark flag alone is enough, and cannot disagree with a
# value of the native option the command line may carry: the Starlark one wins.
_STARLARK_PLATFORMS = Label("@rules_android//flags:android_platforms")

def _android_platforms_transition_impl(_settings, attr):
    platforms = [str(platform) for platform in attr.android_platforms]
    return {
        str(_STARLARK_PLATFORMS): platforms,
    }

_android_platforms_transition = transition(
    implementation = _android_platforms_transition_impl,
    inputs = [],
    outputs = [str(_STARLARK_PLATFORMS)],
)

def _flutter_android_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

flutter_android_build = rule(
    implementation = _flutter_android_build_impl,
    doc = """Builds `targets` for the Android `android_platforms` and forwards their files.

Building it is the same as building `targets` with
`--@rules_android//flags:android_platforms=<android_platforms>`, whatever flags the command line
has. Use it to check an APK for a given ABI, or for several, from a test in an
invocation like a plain `bazel test //...` that does not pass the flag.

The APK of `targets` holds the ABIs the platforms name: one platform builds an
APK for that ABI, several build one APK for all of them.""",
    attrs = {
        "android_platforms": attr.label_list(
            mandatory = True,
            allow_empty = False,
            providers = [platform_common.PlatformInfo],
            doc = """The platforms to build `targets` for, such as
`@rules_android//:arm64-v8a` and `:x86_64`. Each is
named for its ABI, which is the directory rules_android packages its native
libraries into.""",
        ),
        "targets": attr.label_list(
            cfg = _android_platforms_transition,
            mandatory = True,
            doc = "The targets to build, such as a `flutter_android_app`.",
        ),
    },
)
