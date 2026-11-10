"""The `dart_package_metadata` a generated BUILD file declares its package with."""

load("@rules_dart//dart:utils.bzl", "METADATA_TARGET_NAME")

# What a generated BUILD file loads the rule from.
PACKAGE_METADATA_LOAD = 'load("@rules_dart//dart:defs.bzl", "dart_package_metadata")\n'

def _string_line(attr, value):
    return '    {} = "{}",\n'.format(attr, value) if value else ""

def make_package_metadata_content(
        package_name,
        language_version = "",
        version = "",
        code_assets = [],
        build_hook = "",
        link_hook = "",
        license_file = "",
        visibility = "//visibility:public"):
    """The `dart_package_metadata` target stating a generated package's facts.

    Args:
        package_name: The package's name.
        language_version: From its `environment.sdk`, or "".
        version: The version pub resolved, or "".
        code_assets: `dart_code_asset` label strings replacing its build hook.
        build_hook: Its `hook/build.dart`, package-relative, or "".
        link_hook: Its `hook/link.dart`, package-relative, or "".
        license_file: Its `NOTICES` or `LICENSE`, package-relative, or "".
        visibility: The target's visibility.

    Returns:
        BUILD content: the target, without the `load`.
    """
    assets = ""
    if code_assets:
        lines = ["        {},".format(repr(a)) for a in code_assets]
        assets = "    code_assets = [\n{}\n    ],\n".format("\n".join(lines))
    return """\
dart_package_metadata(
    name = "{target}",
    package_name = "{name}",
{language_version}{version}{assets}{build_hook}{link_hook}{license}    visibility = ["{visibility}"],
)
""".format(
        target = METADATA_TARGET_NAME,
        name = package_name,
        language_version = _string_line("language_version", language_version),
        version = _string_line("version", version),
        assets = assets,
        build_hook = _string_line("build_hook", build_hook),
        link_hook = _string_line("link_hook", link_hook),
        license = _string_line("license_file", license_file),
        visibility = visibility,
    )
