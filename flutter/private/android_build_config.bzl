"""The `BuildConfig` class Gradle generates for each Android module.

Gradle writes a `BuildConfig` into every library's namespace, and plugins read
`BuildConfig.DEBUG` and `BUILD_TYPE` from it. rules_android generates none, so
every plugin library gets one from here. Its values are those of the Gradle
build of the same mode (Flutter's Gradle plugin makes the `profile` build type
with `initWith(debug)`, and copies the app's build types, `isDebuggable`
included, to its plugins):

| mode    | `DEBUG` | `BUILD_TYPE` |
|---------|---------|--------------|
| debug   | true    | `debug`      |
| profile | true    | `profile`    |
| release | false   | `release`    |

The mode is the configuration's, as for the engine: `-c dbg` is debug,
`-c opt --@rules_flutter//flutter:profile` is profile, anything else release.
"""

_SOURCE = """\
package {package};

public final class BuildConfig {{
  public static final boolean DEBUG = {debug};
  public static final String LIBRARY_PACKAGE_NAME = "{package}";
  public static final String BUILD_TYPE = "{build_type}";
}}
"""

def _android_build_config_src_impl(ctx):
    out = ctx.actions.declare_file("%s/%s/BuildConfig.java" % (
        ctx.label.name,
        ctx.attr.package.replace(".", "/"),
    ))
    ctx.actions.write(out, _SOURCE.format(
        package = ctx.attr.package,
        debug = "true" if ctx.attr.debug else "false",
        build_type = ctx.attr.build_type,
    ))
    return [DefaultInfo(files = depset([out]))]

_android_build_config_src = rule(
    implementation = _android_build_config_src_impl,
    doc = "Writes `BuildConfig.java` for `package`. Writes the file itself, so it needs no shell.",
    attrs = {
        "package": attr.string(
            mandatory = True,
            doc = "The Android namespace the class is in.",
        ),
        "debug": attr.bool(
            mandatory = True,
            doc = "`BuildConfig.DEBUG`.",
        ),
        "build_type": attr.string(
            mandatory = True,
            doc = "`BuildConfig.BUILD_TYPE`.",
        ),
    },
)

def android_build_config(name, package, tags = None):
    """Declares `name`, the `BuildConfig.java` of `package`, for a library's `srcs`.

    Gradle compiles the class it generates with the module's own sources, so
    it goes in the `srcs` of the plugin's library, not a library of its own.
    Its `DEBUG` and `BUILD_TYPE` follow the build mode of the configuration it
    is built in: see the file's docstring.

    Args:
        name: Name of the target that writes the source.
        package: The plugin's Android namespace.
        tags: Tags for the target.
    """
    _android_build_config_src(
        name = name,
        package = package,
        debug = select({
            "@rules_flutter//flutter/private:dbg": True,
            "@rules_flutter//flutter/private:profile": True,
            "//conditions:default": False,
        }),
        build_type = select({
            "@rules_flutter//flutter/private:dbg": "debug",
            "@rules_flutter//flutter/private:profile": "profile",
            "//conditions:default": "release",
        }),
        tags = tags,
        visibility = ["//visibility:private"],
    )
