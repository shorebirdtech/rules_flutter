"""Flutter Android application bundling.

Produces the native artifacts needed for an Android APK:
- libapp.so (AOT-compiled Dart code), as a native library of the APK
- the app's other native libraries (FFI, Native Assets)
- a flutter_assets/ tree artifact

The user wires these outputs into rules_android's android_binary:

    load("@rules_flutter//flutter:android.bzl", "flutter_android_bundle")

    flutter_application(
        name = "my_app_flutter",
        main = "main.dart",
    )

    flutter_android_bundle(
        name = "my_app_android",
        application = ":my_app_flutter",
    )

    # Put the bundle in android_binary's `deps`: it provides its native
    # libraries as `AndroidNativeLibsInfo`, as an `aar_import` does.
    android_binary(
        name = "my_app",
        manifest = "AndroidManifest.xml",
        nocompress_extensions = [".so"],
        deps = [":my_app_android", ...],
        ...
    )

The bundle's native libraries are one zip of `lib/<abi>/<name>` entries,
stored uncompressed: `libapp.so`, the `native_deps` libraries and the code
assets that ship (in a release or profile build, those the packages' link
hooks keep). `android_binary` builds its dependencies once for each platform
of `--@rules_android//flags:android_platforms` and merges each build's zip
into the APK. The zip is also the `native_libs` output group.

The bundle is built for whichever Android platform `android_binary` builds it
for, and takes its ABI from that platform, so the application behind it (its
AOT compile and any FFI/native deps) is built for the same one. Every native
library is validated to be an ELF shared object with the ABI's machine type
before the APK is packaged; a host-format binary is a hard build error. A
bundle built for a platform that is not Android arm, arm64 or x86_64 fails with the
flag to pass.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "program_assets_action_args")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterSdkRecordInfo")
load("//flutter/private:assemble_directory.bzl", "ASSEMBLE_DIRECTORY_ATTRS", "assemble_directory")
load("//flutter/private:common.bzl", "android_elf_machine_for_abi")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_TOOL_ATTRS", "run_code_assets_tool")
load("//flutter/private:mobile_engine_check.bzl", "check_android_engine")

# The ABIs of devices that can have 16 KB pages: Android's 64-bit ones. Every
# native library packaged for them is checked to be aligned for that.
_SIXTEEN_KB_ABIS = ["arm64-v8a", "x86_64"]
_PAGE_SIZE = 16384

# The attributes `android_abi` and `validate_android_native_libs` read.
ANDROID_NATIVE_LIBS_ATTRS = {
    "_allow_4kb_aligned_native_libraries": attr.label(
        default = "//flutter:allow_4kb_aligned_native_libraries",
        providers = [BuildSettingInfo],
    ),
    "_android_constraint": attr.label(default = "@platforms//os:android"),
    "_arm64_constraint": attr.label(default = "@platforms//cpu:aarch64"),
    "_armv7_constraint": attr.label(default = "@platforms//cpu:armv7"),
    "_validate_tool": attr.label(
        default = "//flutter/private/tools:validate_android_elf.dart",
        allow_single_file = True,
    ),
    "_x86_64_constraint": attr.label(default = "@platforms//cpu:x86_64"),
}

def android_abi(ctx):
    """The ABI of the Android platform the target is built for.

    Args:
        ctx: Rule context, with `ANDROID_NATIVE_LIBS_ATTRS`.

    Returns:
        "armeabi-v7a", "arm64-v8a" or "x86_64", or None for a platform that is
        not Android arm, arm64 or x86_64.
    """
    if ctx.target_platform_has_constraint(ctx.attr._android_constraint[platform_common.ConstraintValueInfo]):
        if ctx.target_platform_has_constraint(ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo]):
            return "arm64-v8a"
        if ctx.target_platform_has_constraint(ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo]):
            return "x86_64"
        if ctx.target_platform_has_constraint(ctx.attr._armv7_constraint[platform_common.ConstraintValueInfo]):
            return "armeabi-v7a"
    return None

def _android_abi(ctx):
    """The ABI of the Android platform this bundle is built for, or a failure."""
    abi = android_abi(ctx)
    if abi:
        return abi
    fail((
        "{label} is built for the platform {platform}, which is not Android arm, arm64 or " +
        "x86_64. An Android app is built for the platforms of --@rules_android//flags:android_platforms: pass " +
        "--@rules_android//flags:android_platforms=@rules_android//:arm64-v8a (and " +
        ":armeabi-v7a or :x86_64 for a second ABI), or build it through flutter_android_build."
    ).format(label = ctx.label, platform = ctx.fragments.platform.platform))

def validate_android_native_libs(ctx, tools, abi, libs, name):
    """Checks that a device of `abi` can load `libs`, in a build action.

    Each library must be an ELF shared object of the ABI's machine type and,
    for a 64-bit ABI, have its segments aligned for 16 KB pages, unless
    `--@rules_flutter//flutter:allow_4kb_aligned_native_libraries` is set.

    The check is a Dart script run by the exec-tools toolchain's `dart`, so it
    runs on any host.

    Args:
        ctx: Rule context, with `ANDROID_NATIVE_LIBS_ATTRS` and the `PORTABLE`
            exec group.
        tools: The `FlutterExecToolsInfo` of the host the action runs on.
        abi: Android ABI string (e.g. "arm64-v8a").
        libs: `.so` files, and `.zip` files of them (an AAR's native
            libraries, as rules_android extracts them).
        name: The name of the stamp file, unique in the package.

    Returns:
        The validation stamp the build must produce.
    """
    validated = ctx.actions.declare_file(name)

    # Every path is an argument, so path mapping can rewrite it.
    args = ctx.actions.args()
    args.add(ctx.file._validate_tool)
    args.add("--abi", abi)
    args.add("--machine", str(android_elf_machine_for_abi(abi)))
    if abi in _SIXTEEN_KB_ABIS and not ctx.attr._allow_4kb_aligned_native_libraries[BuildSettingInfo].value:
        args.add("--min-load-align", str(_PAGE_SIZE))
    args.add("--stamp", validated)
    args.add_all(libs)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._validate_tool] + libs,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [validated],
        mnemonic = "FlutterValidateNativeLibs",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Validating Android native libs for %s %s" % (abi, ctx.label),
    )
    return validated

def _symlink_assets_dir(ctx, flutter_assets):
    """Symlink the flutter_assets tree to `assets/flutter_assets/`, as an APK holds it."""

    # Use label name as prefix to avoid conflicts when multiple bundles
    # exist in the same package (e.g. Tier 1 macro + explicit Tier 2).
    out = ctx.actions.declare_directory(ctx.label.name + "_mi/assets/flutter_assets")
    ctx.actions.symlink(output = out, target_file = flutter_assets)
    return out

def _package_native_libs(ctx, tools, app_info, abi):
    """The app's native libraries as the APK holds them, and their validation.

    One zip of `lib/<abi>/<name>` entries, stored uncompressed: `libapp.so`
    (the AOT output, whatever `gen_snapshot` called it: the engine loads the
    Dart snapshot via `System.loadLibrary("app")`), the `native_deps`
    libraries and the code assets that ship. Which code assets ship is known
    only when a release build's link hooks have run, so the action reads the
    program's assets file, and `android_binary` takes the zip as it takes an
    `aar_import`'s libraries (`AndroidNativeLibsInfo`), for this ABI.

    Every library is validated (`validate_android_native_libs`) before the APK
    is packaged: a library a device cannot load fails the build instead of
    producing an APK that crashes on device. Two libraries under one name fail
    the packaging action: the APK could hold only one of them.

    Args:
        ctx: Rule context.
        tools: The `FlutterExecToolsInfo` of the host the action runs on.
        app_info: The application's `FlutterApplicationInfo`.
        abi: Android ABI string (e.g. "arm64-v8a").

    Returns:
        A tuple of the zip and the validation stamp the build must produce.
    """
    zip = ctx.actions.declare_file("%s_native_libs/libs.zip" % ctx.label.name)
    code_assets = program_assets_action_args(ctx.actions, app_info.program_assets, data = False)
    args = ctx.actions.args()
    args.add("--abi", abi)
    args.add("--output", zip)
    if app_info.aot_output:
        args.add("--library-as", "libapp.so")
        args.add(app_info.aot_output)
    args.add_all(app_info.native_libs, before_each = "--library")
    run_code_assets_tool(
        ctx,
        "android-libs",
        [args, code_assets.args],
        depset(
            ([app_info.aot_output] if app_info.aot_output else []) + list(app_info.native_libs),
            transitive = [code_assets.inputs],
        ),
        [zip],
        mnemonic = "FlutterAndroidNativeLibs",
        progress_message = "Packaging the %s native libraries of %%{label}" % abi,
    )
    validated = validate_android_native_libs(
        ctx,
        tools,
        abi,
        [zip],
        ctx.label.name + "_native_libs.validated",
    )
    return zip, validated

def _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, tools):
    """Copy flutter_assets and add kernel_blob.bin + VM snapshots for debug mode.

    On Android, the debug engine looks for kernel_blob.bin inside
    flutter_assets/ (same convention as `flutter build apk --debug`).
    The vm_snapshot_data and isolate_snapshot_data are needed for the
    kernel service isolate (hot reload and expression evaluation).
    """
    out = ctx.actions.declare_directory(ctx.label.name + "_debug_flutter_assets")

    vm_snapshot = tools.vm_isolate_snapshot
    iso_snapshot = tools.isolate_snapshot
    assemble_directory(
        ctx,
        tools,
        out,
        [
            ("tree", ".", flutter_assets),
            ("file", "kernel_blob.bin", kernel_dill),
            ("file", "vm_snapshot_data", vm_snapshot),
            ("file", "isolate_snapshot_data", iso_snapshot),
        ],
        mnemonic = "FlutterAndroidDebugAssets",
        progress_message = "Assembling debug flutter_assets with kernel and VM snapshots %s" % ctx.label,
    )
    return out

def _copy_assets_with_record(ctx, flutter_assets, record, tools):
    """Copy flutter_assets and add `flutter_sdk.json`, the record of the SDK the app is built with."""
    out = ctx.actions.declare_directory(ctx.label.name + "_recorded_flutter_assets")
    assemble_directory(
        ctx,
        tools,
        out,
        [
            ("tree", ".", flutter_assets),
            ("file", "flutter_sdk.json", record),
        ],
        mnemonic = "FlutterAndroidSdkRecordAssets",
        progress_message = "Adding the Flutter SDK record to flutter_assets %s" % ctx.label,
    )
    return out

def _flutter_android_bundle_impl(ctx):
    """Bundles Flutter compilation outputs for Android packaging."""
    app_info = ctx.attr.application[FlutterApplicationInfo]
    tools = portable_tools(ctx)
    flutter_assets = app_info.flutter_assets
    kernel_dill = app_info.kernel_dill

    # Debug mode: include kernel_blob.bin in flutter_assets for JIT execution.
    if kernel_dill and not app_info.aot_output:
        flutter_assets = _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, tools)

    abi = _android_abi(ctx)

    # The engine must have been built for the app's ABI, and an app of a
    # custom SDK keeps the record of the checked pieces it was built from.
    sdk_record = ctx.attr._sdk_record[FlutterSdkRecordInfo]
    check_android_engine(ctx.label, sdk_record, abi)
    if sdk_record.record:
        flutter_assets = _copy_assets_with_record(ctx, flutter_assets, sdk_record.record, tools)

    packaged, validated = _package_native_libs(ctx, tools, app_info, abi)

    outputs = [flutter_assets, packaged]

    # The flutter_assets tree under `assets/`, for an `android_binary`'s
    # `assets` with `assets_dir = "assets"`. The native libraries are the zip.
    mobile_install_files = []
    if ctx.attr.mobile_install_compatible:
        mobile_install_files.append(_symlink_assets_dir(ctx, flutter_assets))
        outputs.extend(mobile_install_files)

    return [
        DefaultInfo(files = depset(outputs)),
        # What `android_binary` packages, for the ABI it builds this for: the
        # libraries an `aar_import` brings arrive the same way. The empty
        # `CcInfo` is what makes this a dependency `android_binary` accepts.
        AndroidNativeLibsInfo(native_libs = depset([packaged])),
        CcInfo(),
        OutputGroupInfo(
            native_libs = depset([packaged]),
            flutter_assets = depset([flutter_assets]),
            mobile_install = depset(mobile_install_files),
            _validation = depset([validated]),
        ),
    ]

flutter_android_bundle = rule(
    implementation = _flutter_android_bundle_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "mobile_install_compatible": attr.bool(
            doc = """Whether to offer the flutter_assets tree at `assets/flutter_assets/`.

When True (the default), the `mobile_install` output group holds the tree
under `<name>_mi/assets/flutter_assets`, for an `android_binary`'s `assets`
with `assets_dir = "assets"`, which is how `flutter_android_app` packages it.
It holds no native libraries: those are the bundle's one zip
(`AndroidNativeLibsInfo`, the `native_libs` group).

Set to False when nothing packages the tree from this group.""",
            default = True,
        ),
        "_sdk_record": attr.label(
            default = "//flutter/private:sdk_record",
            providers = [FlutterSdkRecordInfo],
        ),
    } | ANDROID_NATIVE_LIBS_ATTRS | ASSEMBLE_DIRECTORY_ATTRS | CODE_ASSETS_TOOL_ATTRS,
    # Packaging copies and checks what the application built, the same bytes on
    # any host.
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["platform"],
    doc = """Bundles Flutter compilation outputs for Android packaging.

Put it in an `android_binary`'s `deps`: it provides the app's native libraries
(`libapp.so`, the `native_deps` libraries and the code assets that ship) as
`AndroidNativeLibsInfo`, one zip of `lib/<abi>/<name>` entries, as an
`aar_import` does; the zip is also its `native_libs` output group. It offers a
flutter_assets tree artifact too.

The bundle is built for the Android platform `android_binary` builds it for,
one for each of `--@rules_android//flags:android_platforms`, and takes its ABI from that platform;
the application behind it is built for the same platform, so the AOT compile
and all native deps target Android with no further flag. An APK for several
ABIs therefore carries `libapp.so` of each. Native libraries are validated to
be ELF for the platform's ABI at packaging time. Building it for a platform
that is not Android arm, arm64 or x86_64 fails, naming the flag to pass.

With `mobile_install_compatible` (the default), its `mobile_install` output
group is the flutter_assets tree at `assets/flutter_assets/`, for an
`android_binary`'s `assets`.""",
)
