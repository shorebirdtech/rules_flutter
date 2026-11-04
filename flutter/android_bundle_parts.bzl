"""Collects what a hot restart reads of an Android app, without building the APK.

A restart needs two things of the app it is restarting: the `flutter_assets`
tree, to see whether an asset moved, and the native libraries the APK packages,
to see whether the process must be replaced rather than restarted. Both are
built well before the APK: the APK is dexed, linked, zipped and signed from
them, which measured 24 s of a 46 s restart on an emulator, none of it needed
when only Dart changed.

The launch target is another rule set's rule (`android_binary`), so no output
group of ours can be added to it. An aspect reaches through it, transitions
included, and meets each dependency in the configuration the APK really used.
Building only its output groups builds only what they hold:

    bazel build <launch target> \\
        --aspects=@rules_flutter//flutter:android_bundle_parts.bzl%flutter_android_bundle_parts_aspect \\
        --output_groups=flutter_android_bundle_parts,flutter_android_native_libs

`flutter_android_bundle_parts` holds the application's `flutter_assets` tree.

`flutter_android_native_libs` holds what `android_binary` takes its native
libraries from, which is more than the Flutter application's own: it links
every `cc_library` (and `cc_import`, `cc_shared_library`) dependency into a
library of its own, packages the shared libraries those bring, and packages
the `jni/` libraries of every AAR below it. So the group holds each such
dependency's linker inputs (static archives, objects and shared libraries) and
each `AndroidNativeLibsInfo` library. A change to any of them is a change to
what the APK carries. It is built in the app's configuration, not the host's:
an exec configuration is left out, since a tool the build runs is not in the
app.

A prebuilt library checked into the workspace (a `cc_import` of a source `.a`
or `.so`) is in it as the source file it is: an output group can hold source
artifacts, and building the group only has to find them, not make them.
"""

load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")

BUNDLE_PARTS_OUTPUT_GROUP = "flutter_android_bundle_parts"
NATIVE_LIBS_OUTPUT_GROUP = "flutter_android_native_libs"

_PartsInfo = provider(
    doc = "Every bundle's assets and native library inputs at or below this node.",
    fields = {
        "assets": "depset[File]",
        "native_libs": "depset[File]",
    },
)

def _dependencies(rule_attr):
    """The collected parts of every dependency, whatever attribute shape holds it."""
    deps = []
    for name in dir(rule_attr):
        value = getattr(rule_attr, name)
        if type(value) == "list":
            items = value
        elif type(value) == "dict":
            items = list(value.keys()) + list(value.values())
        else:
            items = [value]
        for item in items:
            if type(item) == "Target" and _PartsInfo in item:
                deps.append(item[_PartsInfo])
    return deps

def _own_libraries(cc_info, owner):
    """The files the linker is given for `owner`'s own libraries."""
    files = []
    for linker_input in cc_info.linking_context.linker_inputs.to_list():
        if linker_input.owner != owner:
            continue
        for library in linker_input.libraries:
            for file in [
                library.static_library,
                library.pic_static_library,
                library.dynamic_library,
            ] + list(library.objects or []) + list(library.pic_objects or []):
                if file:
                    files.append(file)
    return files

def _flutter_android_bundle_parts_aspect_impl(target, ctx):
    if ctx.configuration.is_tool_configuration():
        return [
            _PartsInfo(assets = depset(), native_libs = depset()),
            OutputGroupInfo(**{
                BUNDLE_PARTS_OUTPUT_GROUP: depset(),
                NATIVE_LIBS_OUTPUT_GROUP: depset(),
            }),
        ]
    assets = []
    native_libs = []

    # The bundle rule is the one that names the application it packages; the
    # application is also reached by the registrant and by plugin libraries,
    # which would otherwise contribute the same files from other nodes.
    if ctx.rule.kind == "flutter_android_bundle":
        app = ctx.rule.attr.application
        if type(app) == "Target" and FlutterApplicationInfo in app:
            assets.append(depset([app[FlutterApplicationInfo].flutter_assets]))

    # What `android_binary` links and packages: cc dependencies' own libraries,
    # and the libraries AARs and Android libraries carry (already transitive).
    if CcInfo in target:
        native_libs.append(depset(_own_libraries(target[CcInfo], target.label)))
    if AndroidNativeLibsInfo in target:
        native_libs.append(target[AndroidNativeLibsInfo].native_libs)

    below = _dependencies(ctx.rule.attr)
    assets_all = depset(transitive = assets + [d.assets for d in below])
    native_all = depset(transitive = native_libs + [d.native_libs for d in below])
    return [
        _PartsInfo(assets = assets_all, native_libs = native_all),
        OutputGroupInfo(**{
            BUNDLE_PARTS_OUTPUT_GROUP: assets_all,
            NATIVE_LIBS_OUTPUT_GROUP: native_all,
        }),
    ]

flutter_android_bundle_parts_aspect = aspect(
    implementation = _flutter_android_bundle_parts_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects the flutter_assets tree and the native library inputs of an Android app below a launch target, in the configuration each was built in.",
)
