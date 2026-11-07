"""The iOS and Android slices of an engine checkout's out dirs.

`flutter_engine_out_dirs` (local_sdk.bzl) reads the checkout; this module
decides which out dir serves each mobile slice and writes the slice targets
(docs/design/design_custom_engine.md, sections 5.1 and 7.2):

* `ios/<mode>:engine`: `Flutter.xcframework` of `ios_<mode>[_unopt]` (device;
  profile and release) or `ios_debug_sim[_unopt][_<cpu>]` (the simulator, which
  is what `debug` means for iOS).
* `android-<arch>/<mode>:engine`: `flutter.jar` of
  `android_<mode>[_unopt]_<arch>`.
* `ios-arm64/<mode>:gen_snapshot_<host>` and
  `android-<arch>/<mode>:gen_snapshot_<host>`: the out dir's gen_snapshot that
  runs on `<host>`.

One more Android ABI is one more entry of `TARGET_PLATFORMS`: the slices here
follow `android_arches()`.
"""

load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load("//flutter/private:engine_labels.bzl", "ENGINE_MODES", "android_arches", "android_engine_cpu")
load("//flutter/private:engine_out_dirs.bzl", "dict_text", "first_existing", "link_into", "out_dir_provenance", "select_out_dir")
load("//flutter/private:toolchains_repo.bzl", "CROSS_COMPILATION_PAIRS")

# The directories flutter_tools searches for a gen_snapshot (`_genSnapshotPath`)
# that a macOS host can run, with the CPUs of the hosts each binary runs on.
# `universal` holds the lipo of both Mac CPUs; a `clang_<cpu>` directory is the
# host toolchain's output, so the CPU is in its name. `.` has no CPU in its
# name: it is the machine the out dir was built on, which is this one.
_GEN_SNAPSHOT_DIRS = [
    (".", None),
    ("universal", ["arm64", "x64"]),
    ("clang_x64", ["x64"]),
    ("clang_arm64", ["arm64"]),
]

_HOST_ARCH = {"darwin-arm64": "arm64", "darwin-x64": "x64"}

def _gen_snapshot_for(out, names, host_arch, machine_arch):
    """The gen_snapshot of `out` that runs on a host of CPU `host_arch`, or None."""
    for directory, runs_on in _GEN_SNAPSHOT_DIRS:
        if host_arch not in (runs_on or [machine_arch]):
            continue
        base = out if directory == "." else out.get_child(directory)
        found = first_existing([base.get_child(name) for name in names])
        if found:
            return found
    return None

def _gen_snapshot_stanza(host, cpu, mode, provenance):
    return """
flutter_gen_snapshot(
    name = "gen_snapshot_{host}",
    binary = ":bin/{host}/gen_snapshot",
    target_cpu = "{cpu}",
    mode = "{mode}",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(host = host, cpu = cpu, mode = mode, provenance = dict_text(provenance))

def _gen_snapshots(repository_ctx, result, package, out, args, name, names, target_cpu, mode, machine_arch):
    """Slices for the gen_snapshot of one AOT out dir, on every host that has one."""
    for host, targets in CROSS_COMPILATION_PAIRS.items():
        if package.split("/")[0] not in targets:
            continue
        slice_key = (package, "gen_snapshot_" + host)
        if host not in _HOST_ARCH:
            result.reasons[slice_key] = "The engine out dirs are read on a Mac, which runs gen_snapshot for macOS hosts; {} is not one.".format(host)
            continue
        found = _gen_snapshot_for(out, names, _HOST_ARCH[host], machine_arch)
        if found == None:
            result.reasons[slice_key] = (
                "The out dir {out} has no {names} that runs on {host}: looked in ., universal and " +
                "clang_{arch}. A universal one comes from ninja -C {build} flutter/lib/snapshot:generate_snapshot_bins."
            ).format(
                out = out,
                names = " or ".join(names),
                host = host,
                arch = _HOST_ARCH[host],
                build = "out/" + name,
            )
            continue

        # One link per host: the same file may serve both Mac CPUs.
        link_into(repository_ctx, found, "{}/bin/{}/gen_snapshot".format(package, host))
        result.provided[slice_key] = _gen_snapshot_stanza(host, target_cpu, mode, out_dir_provenance(name, args))

def _slice_cpus(slice_name):
    """The CPUs of an xcframework platform directory, from its name."""
    body = slice_name[len("ios-"):]
    return [cpu for cpu in ["arm64", "x86_64"] if cpu in body]

def _ios_slices(repository_ctx, result, ctx):
    for mode in ENGINE_MODES:
        package = "ios/" + mode
        sim = mode == "debug"
        cpu = ctx.machine_arch if sim else "arm64"
        what = "the iOS simulator on {}".format(cpu) if sim else "iOS devices"
        pick = select_out_dir(ctx.candidates, ["ios"], mode, cpu, ctx.pins, sim = sim)
        if not pick.name:
            result.reasons[(package, "engine")] = _no_out_dir(ctx, mode, what, pick.error, _ios_advice(mode, sim, cpu))
            if mode != "debug":
                _all_hosts_missing(result, "ios-arm64/" + mode, _no_out_dir(ctx, mode, what, pick.error, _ios_advice(mode, sim, cpu)))
            continue
        out = ctx.out_root.get_child(pick.name)
        args = ctx.args_of[pick.name]
        xcframework = out.get_child("Flutter.xcframework")
        slices = []
        if xcframework.exists:
            slices = sorted([
                child.basename
                for child in xcframework.readdir()
                if child.basename.startswith("ios-") and child.get_child("Flutter.framework").exists
            ])
        wanted = [s for s in slices if s.endswith("-simulator") == sim]
        if not wanted:
            result.reasons[(package, "engine")] = (
                "The out dir {out} has no Flutter.xcframework with {kind} slice (found: {found}): " +
                "build the framework (ninja -C out/{name} flutter/shell/platform/darwin/ios:flutter_framework)."
            ).format(
                out = out,
                kind = "a simulator" if sim else "a device",
                found = ", ".join(slices) or "no xcframework",
                name = pick.name,
            )
        else:
            link_into(repository_ctx, xcframework, package + "/Flutter.xcframework")
            cpus = []
            for s in slices:
                for c in _slice_cpus(s):
                    if c not in cpus:
                        cpus.append(c)
            result.provided[(package, "engine")] = """
filegroup(
    name = "files",
    srcs = glob(["Flutter.xcframework/**"]),
)

flutter_ios_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = {cpus},
    files = ":files",
    binary = ":Flutter.xcframework/{slice}/Flutter.framework/Flutter",
    xcframework_slices = {slices},
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(
                mode = mode,
                cpus = json.encode(cpus),
                slice = wanted[0],
                slices = json.encode(slices),
                provenance = dict_text(out_dir_provenance(pick.name, args)),
            )
        if mode != "debug":
            _gen_snapshots(repository_ctx, result, "ios-arm64/" + mode, out, args, pick.name, ["gen_snapshot_arm64"], "arm64", mode, ctx.machine_arch)

def _android_slices(repository_ctx, result, ctx):
    for arch in android_arches():
        abi = ANDROID_ABI_FOR_ARCH[arch]
        cpu = android_engine_cpu(arch)
        for mode in ENGINE_MODES:
            package = "android-{}/{}".format(arch, mode)
            what = "Android on " + arch
            pick = select_out_dir(ctx.candidates, ["android"], mode, arch, ctx.pins)
            if not pick.name:
                message = _no_out_dir(ctx, mode, what, pick.error, _android_advice(mode, arch))
                result.reasons[(package, "engine")] = message
                if mode != "debug":
                    _all_hosts_missing(result, package, message)
                continue
            out = ctx.out_root.get_child(pick.name)
            args = ctx.args_of[pick.name]
            jar = out.get_child("flutter.jar")
            if not jar.exists:
                result.reasons[(package, "engine")] = (
                    "The out dir {out} has no flutter.jar: build it (ninja -C out/{name} flutter/shell/platform/android:android_jar)."
                ).format(out = out, name = pick.name)
            else:
                link_into(repository_ctx, jar, package + "/flutter.jar")
                result.provided[(package, "engine")] = """
flutter_android_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = ["{cpu}"],
    files = ":flutter.jar",
    binary = ":flutter.jar",
    binary_entry = "lib/{abi}/libflutter.so",
    provenance = {provenance},
    visibility = ["//visibility:public"],
)
""".format(mode = mode, cpu = cpu, abi = abi, provenance = dict_text(out_dir_provenance(pick.name, args)))
            if mode != "debug":
                _gen_snapshots(repository_ctx, result, package, out, args, pick.name, ["gen_snapshot"], cpu, mode, ctx.machine_arch)

def _all_hosts_missing(result, package, message):
    for host, targets in CROSS_COMPILATION_PAIRS.items():
        if package.split("/")[0] in targets:
            result.reasons[(package, "gen_snapshot_" + host)] = message

def _no_out_dir(ctx, mode, what, error, advice):
    return (
        "The engine out dirs under {out} have no {mode} engine for {what}: {error}. Found: {found}. " +
        "Build one in the checkout ({advice}), or build in a mode that exists."
    ).format(out = ctx.out_root, mode = mode, what = what, error = error, found = ctx.found, advice = advice)

def _ios_advice(mode, sim, cpu):
    if sim:
        return "engine/src/flutter/tools/gn --ios --simulator{} --runtime-mode debug, then ninja -C out/{} flutter/shell/platform/darwin/ios:flutter_framework".format(
            " --simulator-cpu=arm64" if cpu == "arm64" else "",
            "ios_debug_sim_arm64" if cpu == "arm64" else "ios_debug_sim",
        )
    return "engine/src/flutter/tools/gn --ios --runtime-mode {mode}, then ninja -C out/ios_{mode} flutter/shell/platform/darwin/ios:flutter_framework flutter/lib/snapshot:generate_snapshot_bins".format(mode = mode)

def _android_advice(mode, arch):
    out = "android_" + mode + ("" if arch == "arm" else "_" + arch)
    return "engine/src/flutter/tools/gn --android --android-cpu={arch} --runtime-mode {mode}, then ninja -C out/{out} flutter/shell/platform/android:android_jar".format(arch = arch, mode = mode, out = out)

def mobile_slices(repository_ctx, out_root, candidates, args_of, pins, found, machine_arch):
    """The iOS and Android slices the out dirs provide, and why the others are missing.

    Args:
        repository_ctx: The adapter's repository context; slices' files are linked into it.
        out_root: The `engine/src/out` path.
        candidates: The out dirs found, as `struct(name, os, mode, sim, unopt, cpu)`.
        args_of: Each out dir's `args.gn`, by directory name.
        pins: Out dir names the user chose, or empty.
        found: A description of the out dirs found, for messages.
        machine_arch: The CPU of the machine reading the out dirs (`arm64`, `x64`).

    Returns:
        `struct(provided, reasons)`: BUILD text by `(package, target)` of the
        slices that exist, and why the others do not.
    """
    result = struct(provided = {}, reasons = {})
    ctx = struct(
        out_root = out_root,
        candidates = candidates,
        args_of = args_of,
        pins = pins,
        found = found,
        machine_arch = machine_arch,
    )
    _ios_slices(repository_ctx, result, ctx)
    _android_slices(repository_ctx, result, ctx)
    return result
