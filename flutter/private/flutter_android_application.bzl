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

    # Wire into android_binary through a cc_library, the way any target that
    # brings prebuilt native libraries is:
    filegroup(
        name = "my_app_native_files",
        srcs = [":my_app_android"],
        output_group = "native_libs",
    )

    cc_library(
        name = "my_app_native",
        srcs = [":my_app_native_files"],
    )

    android_binary(
        name = "my_app",
        manifest = "AndroidManifest.xml",
        deps = [":my_app_native", ...],
        ...
    )

The `native_libs` output group holds the libraries, named as Android loads
them. Give it to a `cc_library` as `srcs` (through a `filegroup` with
`output_group = "native_libs"`) and put that in the `android_binary`'s `deps`:
`android_binary` builds its dependencies once for each platform of
`--@rules_android//flags:android_platforms` and takes the native libraries of each build from its
`cc_library`, packaging them under `lib/<platform name>/`. A jar with
`lib/<abi>/` entries would reach the APK of the first platform alone.

The bundle is built for whichever Android platform `android_binary` builds it
for, and takes its ABI from that platform, so the application behind it (its
AOT compile and any FFI/native deps) is built for the same one. Every native
library is validated to be an ELF shared object with the ABI's machine type
before the APK is packaged; a host-format binary is a hard build error. A
bundle built for a platform that is not Android arm64 or x86_64 fails with the
flag to pass.
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "android_elf_machine_for_abi", "compute_android_jni_path")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")

def _android_abi(ctx):
    """The ABI of the Android platform this bundle is built for.

    Args:
        ctx: Rule context.

    Returns:
        "arm64-v8a" or "x86_64".
    """
    if ctx.target_platform_has_constraint(ctx.attr._android_constraint[platform_common.ConstraintValueInfo]):
        if ctx.target_platform_has_constraint(ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo]):
            return "arm64-v8a"
        if ctx.target_platform_has_constraint(ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo]):
            return "x86_64"
    fail((
        "{label} is built for the platform {platform}, which is not Android arm64 or " +
        "x86_64. An Android app is built for the platforms of --@rules_android//flags:android_platforms: pass " +
        "--@rules_android//flags:android_platforms=@rules_android//:arm64-v8a (and " +
        ":x86_64 for a second ABI), or build it through flutter_android_build."
    ).format(label = ctx.label, platform = ctx.fragments.platform.platform))

# Shell function validating that a native library is an ELF shared object
# with the expected e_machine (2 bytes little-endian at offset 18). Android's
# linker can only load ELF for the APK's ABI; anything else (e.g. a host
# Mach-O dylib) would crash at app startup, so packaging fails instead.
_ELF_VALIDATION_DEF = """\
validate_android_elf() {
  local lib="$1" want_machine="$2" abi="$3"
  local bytes=( $(od -An -v -tu1 -N20 "$lib") )
  if [ "${#bytes[@]}" -lt 20 ] ||
      [ "${bytes[0]}" -ne 127 ] || [ "${bytes[1]}" -ne 69 ] ||
      [ "${bytes[2]}" -ne 76 ] || [ "${bytes[3]}" -ne 70 ]; then
    echo "ERROR: $lib is not an ELF binary. Android ($abi) cannot load it." >&2
    exit 1
  fi
  local machine=$(( bytes[18] | (bytes[19] << 8) ))
  if [ "$machine" -ne "$want_machine" ]; then
    echo "ERROR: $lib has ELF machine $machine; $abi requires $want_machine." >&2
    exit 1
  fi
}"""

def _symlink_to_jni(ctx, src, abi, basename):
    """Create a symlink placing a native lib into the jni/<abi>/ tree."""
    out = ctx.actions.declare_file(
        compute_android_jni_path(ctx.label.name, abi, basename),
    )
    ctx.actions.symlink(output = out, target_file = src)
    return out

def _symlink_assets_dir(ctx, flutter_assets):
    """Symlink the flutter_assets tree into assets/flutter_assets/ for mobile-install."""

    # Use label name as prefix to avoid conflicts when multiple bundles
    # exist in the same package (e.g. Tier 1 macro + explicit Tier 2).
    out = ctx.actions.declare_directory(ctx.label.name + "_mi/assets/flutter_assets")
    ctx.actions.symlink(output = out, target_file = flutter_assets)
    return out

def _stage_native_libs(ctx, aot_output, native_libs, abi):
    """Names the app's native libraries as Android loads them, and validates them.

    The AOT output is `libapp.so` (the Android convention: the engine loads
    the Dart snapshot via System.loadLibrary("app")), whatever the file
    `gen_snapshot` wrote is called. The other libraries keep their names.

    Every library is validated to be an ELF shared object with the ABI's
    machine type before the APK is packaged — a wrong-format library fails the
    build instead of producing an APK that crashes on device. Two libraries
    claiming the same packaged filename are a hard error too: the APK could
    hold only one of them.

    Args:
        ctx: Rule context.
        aot_output: The AOT compile output, packaged as libapp.so. None in
            debug/JIT mode.
        native_libs: Plugin/FFI .so files to package under their own names.
        abi: Android ABI string (e.g. "arm64-v8a").

    Returns:
        A tuple of the libraries to package and the validation stamp the
        build must produce.
    """
    expected_machine = android_elf_machine_for_abi(abi)
    entries = ([("libapp.so", aot_output)] if aot_output else []) + [
        (lib.basename, lib)
        for lib in native_libs
    ]

    libs = []
    seen_basenames = {}
    for basename, lib in entries:
        if basename in seen_basenames:
            fail(
                "flutter_android_bundle: two native libraries would both be " +
                "packaged as lib/{abi}/{basename}: {first} and {second}. ".format(
                    abi = abi,
                    basename = basename,
                    first = seen_basenames[basename].path,
                    second = lib.path,
                ) +
                "Rename one of them — Android can only load one.",
            )
        seen_basenames[basename] = lib
        if lib.basename == basename:
            libs.append(lib)
        else:
            named = ctx.actions.declare_file("{}_native_libs/{}".format(ctx.label.name, basename))
            ctx.actions.symlink(output = named, target_file = lib)
            libs.append(named)

    # $1 = ABI, $2 = its ELF machine, $3 = the stamp, then the libraries. Every
    # path is an argument, so path mapping can rewrite it.
    validated = ctx.actions.declare_file(ctx.label.name + "_native_libs.validated")
    args = ctx.actions.args()
    args.add(abi)
    args.add(str(expected_machine))
    args.add(validated)
    args.add_all(libs)
    ctx.actions.run_shell(
        command = "\n".join([
            _ELF_VALIDATION_DEF,
            'abi="$1"; machine="$2"; stamp="$3"; shift 3',
            'for lib in "$@"; do validate_android_elf "$lib" "$machine" "$abi"; done',
            'echo "$abi" > "$stamp"',
        ]),
        arguments = [args],
        inputs = libs,
        outputs = [validated],
        mnemonic = "FlutterValidateNativeLibs",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Validating Flutter native libs for %s %s" % (abi, ctx.label),
    )
    return libs, validated

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
    cmd = (
        'cp -RL "$1"/. "$2" && cp "$3" "$2/kernel_blob.bin"' +
        ' && cp "$4" "$2/vm_snapshot_data" && cp "$5" "$2/isolate_snapshot_data"'
    )
    args = ctx.actions.args()
    args.add_all([flutter_assets, out, kernel_dill, vm_snapshot, iso_snapshot], expand_directories = False)
    inputs = [flutter_assets, kernel_dill, vm_snapshot, iso_snapshot]

    ctx.actions.run_shell(
        command = cmd,
        arguments = [args],
        inputs = inputs,
        outputs = [out],
        mnemonic = "FlutterAndroidDebugAssets",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Assembling debug flutter_assets with kernel and VM snapshots %s" % ctx.label,
    )
    return out

def _flutter_android_bundle_impl(ctx):
    """Bundles Flutter compilation outputs for Android packaging."""
    app_info = ctx.attr.application[FlutterApplicationInfo]
    tools = portable_tools(ctx)
    flutter_assets = app_info.flutter_assets
    native_libs = list(app_info.native_libs)

    # Native Assets `dynamic_loading_bundle` shared libraries land in
    # `jniLibs/<abi>/` of the APK, with the rest.
    native_libs.extend(app_info.bundled_code_assets.to_list())

    kernel_dill = app_info.kernel_dill

    # Debug mode: include kernel_blob.bin in flutter_assets for JIT execution.
    if kernel_dill and not app_info.aot_output:
        flutter_assets = _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, tools)

    # The AOT output is the libapp.so for Android.
    aot_output = app_info.aot_output
    abi = _android_abi(ctx)

    # In debug mode (JIT) with no plugin/FFI libs there is nothing to
    # package.
    packaged = []
    validations = []
    if aot_output or native_libs:
        packaged, validated = _stage_native_libs(ctx, aot_output, native_libs, abi)
        validations.append(validated)

    outputs = [flutter_assets] + packaged

    # mobile-install compatible output structure.
    mobile_install_files = []
    if ctx.attr.mobile_install_compatible:
        if aot_output:
            jni_libapp = _symlink_to_jni(ctx, aot_output, abi, "libapp.so")
            mobile_install_files.append(jni_libapp)

        for lib in native_libs:
            jni_lib = _symlink_to_jni(ctx, lib, abi, lib.basename)
            mobile_install_files.append(jni_lib)

        assets_dir = _symlink_assets_dir(ctx, flutter_assets)
        mobile_install_files.append(assets_dir)

        outputs.extend(mobile_install_files)

    return [
        DefaultInfo(files = depset(outputs)),
        OutputGroupInfo(
            native_libs = depset(packaged),
            flutter_assets = depset([flutter_assets]),
            mobile_install = depset(mobile_install_files),
            _validation = depset(validations),
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
            doc = """Whether to produce output structured for `bazel mobile-install`.

When True (the default), native libs are symlinked into jni/<abi>/ and
flutter assets into assets/flutter_assets/, matching the directory layout
that mobile-install expects. A `mobile_install` output group is also
provided for selective fetching.

Set to False if you only build release APKs and do not need mobile-install.""",
            default = True,
        ),
        "_android_constraint": attr.label(default = "@platforms//os:android"),
        "_arm64_constraint": attr.label(default = "@platforms//cpu:aarch64"),
        "_x86_64_constraint": attr.label(default = "@platforms//cpu:x86_64"),
    },
    # Packaging copies and checks what the application built, the same bytes on
    # any host.
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["platform"],
    doc = """Bundles Flutter compilation outputs for Android packaging.

Offers `libapp.so` (and the app's other native libraries) as the `native_libs`
output group, for a `cc_library` to give `android_binary` to package, and a
flutter_assets tree artifact.

The bundle is built for the Android platform `android_binary` builds it for,
one for each of `--@rules_android//flags:android_platforms`, and takes its ABI from that platform;
the application behind it is built for the same platform, so the AOT compile
and all native deps target Android with no further flag. An APK for several
ABIs therefore carries `libapp.so` of each. Native libraries are validated to
be ELF for the platform's ABI at packaging time. Building it for a platform
that is not Android arm64 or x86_64 fails, naming the flag to pass.

By default, outputs are also structured for `bazel mobile-install` compatibility.
Use the wrapping android_binary target with `bazel mobile-install` for fast
incremental deployment to a connected device.""",
)
