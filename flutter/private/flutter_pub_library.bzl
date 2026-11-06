"""The two rules a Flutter pub package is built from.

Pub allows packages to depend on each other (`dio` imports `dio_web_adapter`,
which imports `dio`) and Bazel does not allow a dependency cycle, so a pub
package is split in two, as rules_dart's `pub.from_lock()` splits it (see
`@rules_dart//dart/pub:pub_library.bzl`):

* `flutter_pub_member` is one package: its files, and what it states about
  itself that needs nothing but its own archive. Its Dart side is
  rules_dart's `DartPackageMemberInfo`; what only Flutter knows (the plugin it
  registers, its per-platform native libraries, the assets, fonts and shaders
  it bundles) is a `FlutterPubMemberInfo` beside it.
* `flutter_pub_library` is the dependency cycle of one or more members, and
  everything the cycle depends on outside itself. It builds one `DartInfo`
  with a package record for each member, and one `FlutterInfo` that merges
  what each member contributes. Each package keeps its own name, `lib_root`
  and language version, so `package_config.json` cannot tell it from packages
  built one to a target; and what a package bundles is bundled under its own
  `packages/<name>/`, whichever member an app depends on.

The library reads its members' providers itself, so nothing Flutter adds has to
pass through rules_dart. It accepts rules_dart's own `pub_package_member` too,
which a pure-Dart package is, so one cycle can mix packages of both kinds.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info", "web_compiler_reset")
load("@rules_dart//dart/pub:pub_library.bzl", "DartPackageMemberInfo", "dart_package_member_info")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_library.bzl", "SKY_ENGINE_ATTR", "flutter_analyzable_info_of_packages")
load("//flutter/private:flutter_plugin.bzl", "PLUGIN_PACKAGE_ATTRS", "plugin_contributions")

FlutterPubMemberInfo = provider(
    doc = "What a Flutter pub package contributes to `FlutterInfo`, beyond its Dart package.",
    fields = {
        "contributions": "dict: The keyword arguments of `flutter_info()` for what this package itself contributes (plugin, native libraries, assets, fonts, shaders).",
    },
)

def _flutter_pub_member_impl(ctx):
    package_name = ctx.attr.package_name
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )
    return [
        dart_package_member_info(
            label = ctx.label,
            package_name = package_name,
            language_version = ctx.attr.language_version,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
            code_assets = ctx.attr.code_assets,
            version = ctx.attr.version,
            link_hook = ctx.file.link_hook,
            license_file = ctx.file.license_file,
            has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
        ),
        FlutterPubMemberInfo(
            contributions = plugin_contributions(
                ctx,
                package_name,
                declares_plugin = bool(ctx.attr.plugin_platforms_json or ctx.attr.platforms),
            ),
        ),
    ]

flutter_pub_member = rule(
    implementation = _flutter_pub_member_impl,
    attrs = PLUGIN_PACKAGE_ATTRS | {
        "package_name": attr.string(
            mandatory = True,
            doc = "The pub package's name.",
        ),
    },
    doc = "One Flutter pub package's files and facts, which a `flutter_pub_library` builds; not a library by itself. A plugin when `plugin_platforms_json` says so; otherwise it contributes only its assets, fonts and shaders.",
)

def _flutter_pub_library_impl(ctx):
    members = [m[DartPackageMemberInfo] for m in ctx.attr.members]
    srcs = [f for m in members for f in m.srcs]
    resources = [f for m in members for f in m.resources]
    packages = [m.package for m in members]

    # What each member of Flutter's own kind adds. A member of rules_dart's has
    # nothing to add.
    contributions = {}
    for member in ctx.attr.members:
        if FlutterPubMemberInfo in member:
            for channel, values in member[FlutterPubMemberInfo].contributions.items():
                contributions.setdefault(channel, []).extend(values)

    # The Android libraries of the members' `exports` are the ones this library
    # `exports` (see the attribute): the same labels, written once for each.
    # Disagreeing would hide a plugin's library from the APK's dexing, so it is
    # an error here rather than a missing class there.
    member_libs = sorted([entry.lib.label for entry in contributions.get("android_libs", [])])
    exported = sorted([lib.label for lib in ctx.attr.exports])
    if member_libs != exported:
        fail(
            "%s: its `exports` are %s but its members' are %s. They are the same Android libraries." %
            (ctx.label, [str(lib) for lib in exported], [str(lib) for lib in member_libs]),
        )

    return [
        DefaultInfo(
            files = depset(srcs + resources),
            runfiles = ctx.runfiles(files = srcs + resources),
        ),
        dart_info(
            label = ctx.label,
            packages = packages,
            srcs = srcs,
            resources = resources,
            deps = ctx.attr.deps,
        ),
        flutter_analyzable_info_of_packages(ctx, packages, srcs, resources),
        flutter_info(deps = ctx.attr.deps, **contributions),
    ]

flutter_pub_library = rule(
    implementation = _flutter_pub_library_impl,
    # A pub package cannot `select()` on the web compiler, so it is built once
    # whichever web compilers an app reaching it compiles for.
    cfg = web_compiler_reset,
    attrs = {
        "members": attr.label_list(
            providers = [DartPackageMemberInfo],
            mandatory = True,
            doc = "The packages of one dependency cycle, or the one package that is in none: `flutter_pub_member`s and rules_dart's `pub_package_member`s.",
        ),
        "deps": attr.label_list(
            providers = [DartInfo],
            doc = "The libraries of the packages the members depend on outside the cycle.",
        ),
        "exports": attr.label_list(
            providers = [JavaInfo],
            doc = "The members' Android libraries, under a `select()` on Android as theirs are. Named `exports` so that rules_android's dex aspect, which follows `deps`, `exports` and `runtime_deps`, reaches them from an APK that depends on this library through `flutter_android_plugin_libs`. What reaches `FlutterInfo` is the members' own.",
        ),
        "_sky_engine": SKY_ENGINE_ATTR,
    },
    doc = "A Flutter pub package as a library: its dependency cycle's packages, built as one target.",
)
