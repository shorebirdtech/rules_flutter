"""An Android library that brings prebuilt native libraries, as an `aar_import` does."""

load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")

def _aar_like_impl(ctx):
    return [
        ctx.attr.lib[JavaInfo],
        AndroidNativeLibsInfo(native_libs = depset([ctx.file.native_libs])),
    ]

aar_like = rule(
    implementation = _aar_like_impl,
    attrs = {
        "lib": attr.label(mandatory = True, providers = [JavaInfo]),
        "native_libs": attr.label(
            doc = "The zip of the AAR's `.so` files, as `aar_import` extracts it.",
            mandatory = True,
            allow_single_file = [".zip"],
        ),
    },
    doc = "Forwards `lib` and offers `native_libs` as an AAR's native libraries.",
)
