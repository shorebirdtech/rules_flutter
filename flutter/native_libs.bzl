"""Collects the native libraries a launch target bundles, without the bundle.

A hot restart keeps the process, and with it every library the process has
`dlopen`ed, so `app.restart` asks first whether those libraries moved and
relaunches if they did. Answering that by building the launch target costs a
whole bundle per restart: on macOS the kernel, App.framework, the copy into
the `.app` and its signature, for a Dart-only edit that changed none of them.

This aspect is the cheaper question. Applied to the launch target, it rides
every label edge (transitions included, the way `native_hot_patch.bzl` does)
to each `flutter_application`, and puts that application's bundled native
libraries in one output group. Building only that group builds the libraries
and nothing of the bundle:

    bazel build <launch target> \\
        --aspects=@rules_flutter//flutter:native_libs.bzl%flutter_native_libs_aspect \\
        --output_groups=flutter_native_libs

The libraries are the ones the platform rules bundle and the dev config's
`nativeLibs` lists: `native_deps` and `dynamic_loading_bundle` code assets.
Built files only: a checked-in prebuilt library is never built, and the build
event stream names a source by its path in its own repository, not in the
execution root. Exec configurations are left out: a tool that links one of
these libraries runs in the build, not in the app.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")

NATIVE_LIBS_OUTPUT_GROUP = "flutter_native_libs"

_NativeLibsInfo = provider(
    doc = "The bundled native libraries of every flutter_application at or below this node.",
    fields = {"files": "depset[File]"},
)

def _dependencies(rule_attr):
    deps = []
    for name in dir(rule_attr):
        value = getattr(rule_attr, name)
        if type(value) == "list":
            items = value
        elif type(value) == "dict":
            # `macos_application` takes its frameworks as a label-keyed dict.
            items = list(value.keys()) + list(value.values())
        else:
            items = [value]
        for item in items:
            if type(item) == "Target" and _NativeLibsInfo in item:
                deps.append(item[_NativeLibsInfo].files)
    return deps

def _flutter_native_libs_aspect_impl(target, ctx):
    if ctx.configuration.is_tool_configuration():
        files = depset()
    else:
        direct = []
        if FlutterApplicationInfo in target:
            info = target[FlutterApplicationInfo]
            direct = [
                f
                for f in info.native_libs + info.bundled_code_assets.to_list()
                if not f.is_source
            ]
        files = depset(direct, transitive = _dependencies(ctx.rule.attr))
    return [
        _NativeLibsInfo(files = files),
        OutputGroupInfo(**{NATIVE_LIBS_OUTPUT_GROUP: files}),
    ]

flutter_native_libs_aspect = aspect(
    implementation = _flutter_native_libs_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects the bundled native libraries of every `flutter_application` below a launch target, in the configuration each was built in.",
)
