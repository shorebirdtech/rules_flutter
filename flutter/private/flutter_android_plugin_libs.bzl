"""The Android libraries of the plugins an application depends on.

`flutter_android_plugin_libs(application = ...)` is what `flutter_android_app`
puts on its `android_binary` and its plugin registrant, in place of a library
for every package of the lock. An application's plugins are known only after
analysis has read its dependency graph (`FlutterApplicationInfo.android_libs`),
and a BUILD file cannot name them, so this rule links them: it returns what a
`kt_android_library` listing those libraries in `exports` would, so that
`android_binary` and the registrant compile and package them as ordinary
dependencies.

It also checks the Maven artifacts the linked plugins' Gradle builds declare
against what `@rules_android_maven` resolved, for those plugins only: an app
that does not link a plugin never needs its artifacts.
"""

load("@rules_android//providers:providers.bzl", "AndroidCcLinkParamsInfo", "AndroidLibraryResourceClassJarProvider", "AndroidNativeLibsInfo", "StarlarkAndroidResourcesInfo")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_java//java/common:proguard_spec_info.bzl", "ProguardSpecInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:android_plugin_maven.bzl", "maven_check_message")

FlutterAndroidMavenInfo = provider(
    doc = "What a pub hub's Android plugins declare in their Gradle builds, and what `@rules_android_maven` resolved.",
    fields = {
        "data": "dict: `hub` (str), `resolved` (dict of `group:artifact` to version) and `packages` (list of dicts with `package`, `version`, `deps` and `errors`), as `maven_check_message` reads it.",
    },
)

def _flutter_android_maven_requirements_impl(ctx):
    return [FlutterAndroidMavenInfo(data = json.decode(ctx.attr.data))]

flutter_android_maven_requirements = rule(
    implementation = _flutter_android_maven_requirements_impl,
    attrs = {
        "data": attr.string(
            doc = "The JSON the pub hub's Android Maven repository writes.",
            mandatory = True,
        ),
    },
    doc = "Carries a pub hub's Android Maven requirements to the `flutter_android_plugin_libs` that checks them.",
)

def _merge_resources(infos):
    """One `StarlarkAndroidResourcesInfo` for all of `infos`.

    As rules_android merges the resources of a library's `exports`: every
    depset is the union of the inputs', and the R.txt files of one Java package
    stay together. The merged target defines no resources of its own, so it
    names no package.
    """
    packages = {}
    for info in infos:
        for package, r_txts in info.packages_to_r_txts.items():
            packages.setdefault(package, []).append(r_txts)

    def union(field):
        return depset(
            transitive = [getattr(info, field) for info in infos],
            order = "preorder",
        )

    return StarlarkAndroidResourcesInfo(
        direct_resources_nodes = union("direct_resources_nodes"),
        transitive_resources_nodes = union("transitive_resources_nodes"),
        transitive_assets = union("transitive_assets"),
        transitive_assets_symbols = union("transitive_assets_symbols"),
        transitive_compiled_assets = union("transitive_compiled_assets"),
        direct_compiled_resources = union("direct_compiled_resources"),
        transitive_compiled_resources = union("transitive_compiled_resources"),
        transitive_compiled_resources_with_public_xml = union("transitive_compiled_resources_with_public_xml"),
        transitive_manifests = union("transitive_manifests"),
        transitive_r_txts = union("transitive_r_txts"),
        transitive_resource_files = union("transitive_resource_files"),
        packages_to_r_txts = {
            package: depset(transitive = r_txts, order = "preorder")
            for package, r_txts in packages.items()
        },
        transitive_resource_apks = union("transitive_resource_apks"),
        package = "",
    )

def _providers_of(libs, provider_type):
    return [lib[provider_type] for lib in libs if provider_type in lib]

def link_android_libs(libs):
    """The providers of a `kt_android_library` that exports `libs`.

    Args:
        libs: List of Targets: Android libraries (`JavaInfo`, and the rest of
            what `android_library` provides).

    Returns:
        A list of providers: `JavaInfo`, and for each of the others a library
        provides, the merge of the libraries'. For no libraries, an empty
        `JavaInfo`: a library that exports nothing is still a library.
    """
    providers = [java_common.merge([lib[JavaInfo] for lib in libs])]

    resources = _providers_of(libs, StarlarkAndroidResourcesInfo)
    if resources:
        providers.append(_merge_resources(resources))

    jars = _providers_of(libs, AndroidLibraryResourceClassJarProvider)
    if jars:
        providers.append(AndroidLibraryResourceClassJarProvider(
            jars = depset(transitive = [p.jars for p in jars], order = "preorder"),
        ))

    native_libs = _providers_of(libs, AndroidNativeLibsInfo)
    if native_libs:
        providers.append(AndroidNativeLibsInfo(
            native_libs = depset(transitive = [p.native_libs for p in native_libs], order = "preorder"),
        ))

    link_params = _providers_of(libs, AndroidCcLinkParamsInfo)
    if link_params:
        providers.append(AndroidCcLinkParamsInfo(
            link_params = cc_common.merge_cc_infos(cc_infos = [p.link_params for p in link_params]),
        ))

    proguard = _providers_of(libs, ProguardSpecInfo)
    if proguard:
        providers.append(ProguardSpecInfo(
            specs = depset(transitive = [p.specs for p in proguard], order = "preorder"),
        ))
    return providers

def _flutter_android_plugin_libs_impl(ctx):
    entries = ctx.attr.deps[FlutterApplicationInfo].android_libs.to_list()
    if ctx.attr.maven:
        message = maven_check_message(
            ctx.attr.maven[FlutterAndroidMavenInfo].data,
            {entry.package: True for entry in entries},
        )
        if message:
            fail(message)

    libs = []
    for entry in entries:
        if entry.lib not in libs:
            libs.append(entry.lib)
    return [DefaultInfo()] + link_android_libs(libs)

flutter_android_plugin_libs = rule(
    implementation = _flutter_android_plugin_libs_impl,
    attrs = {
        "deps": attr.label(
            doc = "The `flutter_application` whose plugins' Android libraries to link: those of the plugins it depends on, and no others. Named `deps` so that rules_android's dex aspect, which follows `deps`, `exports` and `runtime_deps`, walks from here through the application's `deps` and each library's `exports` to the plugins' Android libraries and dexes them one at a time, as it does for any library an APK depends on.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "maven": attr.label(
            doc = "The pub hub's Android Maven requirements (`@<hub>//android:maven_requirements`), to check those of the linked plugins against `@rules_android_maven`. Leave unset when no linked plugin comes from a pub hub.",
            providers = [FlutterAndroidMavenInfo],
        ),
    },
    doc = "Links the Android libraries of the plugins an application depends on, as a library exporting them would, and fails when `@rules_android_maven` lacks what their Gradle builds declare.",
)
