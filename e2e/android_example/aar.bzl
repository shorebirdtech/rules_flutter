"""Builds a small AAR carrying a native library, for the restart e2e."""

def _android_archive_impl(ctx):
    manifest = ctx.actions.declare_file(ctx.label.name + "/AndroidManifest.xml")
    ctx.actions.write(manifest, """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="{package}" />
""".format(package = ctx.attr.package))
    jar_manifest = ctx.actions.declare_file(ctx.label.name + "/MANIFEST.MF")
    ctx.actions.write(jar_manifest, "Manifest-Version: 1.0\n")
    classes = ctx.actions.declare_file(ctx.label.name + "/classes.jar")
    resources = ctx.actions.declare_file(ctx.label.name + "/R.txt")
    ctx.actions.write(resources, "")

    zipper = ctx.executable._zipper
    ctx.actions.run(
        executable = zipper,
        arguments = ["c", classes.path, "META-INF/MANIFEST.MF=" + jar_manifest.path],
        inputs = [jar_manifest],
        outputs = [classes],
        mnemonic = "AarClasses",
    )

    # The one ABI this workspace builds (--@rules_android//flags:android_platforms
    # in .bazelrc), named as an AAR names the directory of its libraries.
    library = ctx.file.library
    aar = ctx.actions.declare_file(ctx.label.name + ".aar")
    ctx.actions.run(
        executable = zipper,
        arguments = [
            "c",
            aar.path,
            "AndroidManifest.xml=" + manifest.path,
            "classes.jar=" + classes.path,
            "R.txt=" + resources.path,
            "jni/arm64-v8a/" + library.basename + "=" + library.path,
        ],
        inputs = [manifest, classes, resources, library],
        outputs = [aar],
        mnemonic = "AarZip",
    )
    return [DefaultInfo(files = depset([aar]))]

android_archive = rule(
    implementation = _android_archive_impl,
    attrs = {
        "library": attr.label(allow_single_file = [".so"], mandatory = True),
        "package": attr.string(mandatory = True),
        "_zipper": attr.label(
            default = "@bazel_tools//tools/zip:zipper",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "An AAR holding `library` as its only native library, for arm64-v8a.",
)
