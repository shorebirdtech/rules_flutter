"""Fails the build of an Apple app whose Info.plist sets a version key itself.

rules_apple replaces `CFBundleShortVersionString` and `CFBundleVersion` with
the app's version, so a literal in the plist that differs from it would be
dropped without a word.
This rule runs `check_apple_version_keys.dart` over the plist as a validation
action: the app's `_validation` output group carries it, so building the app
fails with the key, the value and what to set instead.
"""

load("@build_bazel_rules_apple//apple:providers.bzl", "AppleBundleVersionInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")

def _impl(ctx):
    tools = portable_tools(ctx)
    stamp = ctx.actions.declare_file(ctx.label.name + ".checked")

    args = ctx.actions.args()
    args.add(ctx.file._tool)
    args.add("--plist", ctx.file.plist)
    args.add("--name", ctx.attr.plist_name or ctx.file.plist.short_path)
    version_file = ctx.attr.version[AppleBundleVersionInfo].version_file
    args.add("--version-file", version_file)
    args.add("--app", ctx.attr.app_label)
    args.add("--rule", ctx.attr.rule_name)
    args.add("--stamp", stamp)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._tool, ctx.file._merge_plists, ctx.file._plist_binary, ctx.file.plist, version_file],
            transitive = [tools.sdk_files.run],
        ),
        outputs = [stamp],
        mnemonic = "FlutterCheckAppleVersion",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Checking the version keys of %s" % ctx.label,
    )
    return [
        DefaultInfo(files = depset([stamp])),
        OutputGroupInfo(_validation = depset([stamp])),
    ]

flutter_apple_version_check = rule(
    implementation = _impl,
    attrs = {
        "plist": attr.label(
            doc = "The Info.plist, XML or binary.",
            allow_single_file = True,
            mandatory = True,
        ),
        "plist_name": attr.string(
            doc = "The plist as the user knows it, for the message. " +
                  "Defaults to the file's path.",
        ),
        "version": attr.label(
            doc = "The app's version, whose values rules_apple puts in the " +
                  "plist's version keys.",
            providers = [AppleBundleVersionInfo],
            mandatory = True,
        ),
        "app_label": attr.string(
            doc = "The label of the app, for the message.",
            mandatory = True,
        ),
        "rule_name": attr.string(
            doc = "The macro that declares the app, for the message.",
            mandatory = True,
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:check_apple_version_keys.dart",
            allow_single_file = True,
        ),
        "_merge_plists": attr.label(
            default = "//flutter/private/tools:merge_plists.dart",
            allow_single_file = True,
        ),
        "_plist_binary": attr.label(
            default = "//flutter/private/tools:plist_binary.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Validates that an Info.plist leaves the version keys to the app's version.",
)
