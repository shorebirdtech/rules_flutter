"""Copies of the files an action takes of the Flutter SDK.

A local sandbox links an action's inputs, and the `dart` launcher looks for
the VM and its snapshots beside its resolved path, so through a link it finds
the whole SDK: a sandboxed build passes however short an action's inputs
fall. Only a remote executor, which has nothing but the declared inputs,
shows the gap. `sdk_set_copy` lays out real copies of exactly the files an
action declares, and `sdk_sets_test` runs the tools against them.
"""

_TOOLCHAIN = Label("//flutter:toolchain_type")

def _relative(f, root_name):
    """The part of `f`'s path after the `root_name` directory, or None."""
    _, found, after = f.path.rpartition("/%s/" % root_name)
    return after if found else None

def _sdk_set_copy_impl(ctx):
    sdk = ctx.toolchains[_TOOLCHAIN].flutter_sdk_info
    out = ctx.actions.declare_directory(ctx.label.name)
    files = []
    args = ctx.actions.args()
    args.add(out.path)

    def copy(path, f):
        files.append(f)
        args.add(path)
        args.add(f)

    # The Dart SDK's files keep their place under `dart-sdk/`.
    for name in ctx.attr.sets:
        for f in getattr(sdk.sdk_files, name).to_list():
            copy("dart-sdk/" + _relative(f, "dart-sdk"), f)
    for name in ctx.attr.fields:
        f = getattr(sdk, name)
        inside = _relative(f, "dart-sdk")
        copy("dart-sdk/" + inside if inside else "extra/" + f.basename, f)
    for f in ctx.files.extra:
        copy("extra/" + f.basename, f)

    # A copy, not a link, so that nothing is found beside it.
    ctx.actions.run(
        executable = ctx.executable._copier,
        arguments = [args],
        inputs = files,
        outputs = [out],
        mnemonic = "SdkSetCopy",
        progress_message = "Copying the Flutter SDK files of %s" % ctx.label,
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles([out]))]

sdk_set_copy = rule(
    implementation = _sdk_set_copy_impl,
    attrs = {
        "sets": attr.string_list(
            doc = "Sets of `FlutterSdkInfo.sdk_files` to copy, by name.",
            allow_empty = True,
        ),
        "fields": attr.string_list(
            doc = "`FlutterSdkInfo` fields naming a file to copy too (`frontend_server`): " +
                  "under `dart-sdk/` when the file is part of the SDK, else under `extra/`.",
        ),
        "extra": attr.label_list(
            doc = "Other files, copied under `extra/`.",
            allow_files = True,
        ),
        "_copier": attr.label(
            default = ":copy_files",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN],
    doc = "A directory holding copies of some of the Flutter SDK's files, laid out as the SDK is.",
)
