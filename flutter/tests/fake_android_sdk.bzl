"""An Android SDK with only the `adb` that rules_android's SDK repository picks per host."""

load("@rules_android//providers:providers.bzl", "AndroidSdkInfo")

def _fake_android_sdk_impl(ctx):
    return [AndroidSdkInfo(
        build_tools_version = None,
        framework_aidl = None,
        aidl_lib = None,
        android_jar = None,
        source_properties = None,
        shrinked_android_jar = None,  # typos:ignore-line
        main_dex_classes = None,
        adb = ctx.attr.adb[DefaultInfo].files_to_run,
        dx = None,
        main_dex_list_creator = None,
        aidl = None,
        aapt = None,
        aapt2 = None,
        apk_builder = None,
        apk_signer = None,
        proguard = None,
        zip_align = None,
        system = None,
        legacy_main_dex_list_generator = None,
    )]

# Shaped as rules_android's `android_sdk`: its `adb` is a `select` on the
# platform the SDK's tools run on, and an exec-configured dependency of
# whoever uses the SDK, so it is analysed for the host that runs the test.
fake_android_sdk = rule(
    implementation = _fake_android_sdk_impl,
    attrs = {
        "adb": attr.label(
            allow_single_file = True,
            cfg = "exec",
            executable = True,
            mandatory = True,
        ),
    },
    provides = [AndroidSdkInfo],
)
