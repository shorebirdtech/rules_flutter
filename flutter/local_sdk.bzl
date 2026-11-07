"""Adapters that hand a Flutter checkout and its engine out dirs to rules_flutter.

The engine is built outside Bazel (`et`, or `tools/gn` and ninja, in the
developer's checkout), and these repository rules point at it, like a precompiled
`protoc`: `flutter_engine_out_dirs` is an engine source (the contract of
`@rules_flutter//flutter:engine.bzl`) over the out dirs, and
`flutter_checkout_framework` is a framework source over the checkout's packages.

The checkout's path is machine-local, so it never appears in MODULE.bazel. The
committed MODULE.bazel declares the SDK without a path; the path and the choice
to use the SDK live in the untracked `.bazelrc.user`:

```
common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter
common --@rules_flutter//flutter:sdk=local
```

MODULE.bazel:

```starlark
local_framework = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_checkout_framework")
local_engine = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_engine_out_dirs")
local_framework(name = "flutter_local_framework")
local_engine(name = "flutter_local_engine")

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(name = "local", framework = "@flutter_local_framework", engine = "@flutter_local_engine")
```

Nothing is read until a build selects the SDK. Where the variable is not set the
repositories still load, with targets that fail when something uses them, so
`bazel query` works on a machine without a checkout.

When the out dirs of a slot are ambiguous (both `host_debug_arm64` and
`host_debug_unopt_arm64`), pin one with `--repo_env=FLUTTER_LOCAL_ENGINES=host_debug_unopt_arm64,host_release_arm64`.
"""

load("//flutter/private:engine_labels.bzl", "contract_slices", "native_target")
load("//flutter/private:engine_out_dirs.bzl", "effective_cpu", "parse_args_gn", "parse_out_dir_name", "select_out_dir")
load("//flutter/private:framework_source.bzl", "FRAMEWORK_JSON")

_ENGINE_LOAD = 'load("@rules_flutter//flutter:engine.bzl", "flutter_gen_snapshot", "flutter_host_tools", "flutter_macos_engine_slice", "flutter_missing_slice", "flutter_platform_kernel")\n'

def _unset_message(env):
    return (
        "{env} is not set. Point it at a flutter/flutter checkout whose engine is built in " +
        "engine/src/out, and select the SDK, in .bazelrc.user:\n" +
        "    common --repo_env={env}=/path/to/flutter\n" +
        "    common --@rules_flutter//flutter:sdk=<the SDK's name>"
    ).format(env = env)

def _checkout_path(repository_ctx, env):
    """The checkout's path: the directory of the file `checkout` names, or the environment variable's value."""
    if repository_ctx.attr.checkout:
        return str(repository_ctx.path(repository_ctx.attr.checkout).dirname)
    return repository_ctx.getenv(env)

_CHECKOUT_ATTR = attr.label(
    doc = "A file at the root of a checkout that another repository lays out, in place of the " +
          "environment variable: for a checkout that Bazel itself produces, such as the stand-in a test builds " +
          "from the official artifacts.",
    allow_single_file = True,
)

def _checkout_framework_impl(repository_ctx):
    env = repository_ctx.attr.path_env
    repository_ctx.file("BUILD.bazel", 'exports_files(["%s"], visibility = ["//visibility:public"])\n' % FRAMEWORK_JSON)
    checkout = _checkout_path(repository_ctx, env)
    if not checkout:
        repository_ctx.file(FRAMEWORK_JSON, json.encode({"unset": _unset_message(env)}) + "\n")
        return
    root = repository_ctx.path(checkout)
    if not root.get_child("packages").get_child("flutter").get_child("pubspec.yaml").exists:
        fail("{}={} is not a flutter/flutter checkout: it has no packages/flutter/pubspec.yaml.".format(env, checkout))

    # The packages and the files the framework expects of its tree, linked so
    # that an edit to the checkout is seen.
    repository_ctx.symlink(root.get_child("packages"), "packages")
    repository_ctx.watch_tree(root.get_child("packages"))
    for linked in ["bin/internal", "engine/src/flutter/sky/packages/sky_engine"]:
        source = root.get_child(linked.split("/")[0])
        for part in linked.split("/")[1:]:
            source = source.get_child(part)
        if not source.exists:
            fail("{}={} has no {}.".format(env, checkout, linked))
        repository_ctx.symlink(source, linked)
        repository_ctx.watch_tree(source)

    # Which commit it is, and whether it is clean: the host's git, since only
    # git can say what a developer's own checkout is.
    commit = ""
    dirty = False
    head = repository_ctx.execute(["git", "-C", checkout, "rev-parse", "HEAD"])
    if head.return_code == 0:
        commit = head.stdout.strip()
        status = repository_ctx.execute(["git", "-C", checkout, "status", "--porcelain"])
        dirty = status.return_code == 0 and bool(status.stdout.strip())
        git_dir = root.get_child(".git")
        if git_dir.is_dir:
            repository_ctx.watch(git_dir.get_child("HEAD"))
            ref = repository_ctx.read(git_dir.get_child("HEAD")).strip()
            if ref.startswith("ref: "):
                repository_ctx.watch(git_dir.get_child(ref[len("ref: "):]))
            repository_ctx.watch(git_dir.get_child("packed-refs"))

    version_file = root.get_child("bin").get_child("cache").get_child("flutter.version.json")
    if version_file.exists:
        repository_ctx.watch(version_file)
        version = json.decode(repository_ctx.read(version_file))["flutterVersion"]
    else:
        describe = repository_ctx.execute(["git", "-C", checkout, "describe", "--tags"])
        if describe.return_code != 0:
            fail("Cannot tell which Flutter version {} is: it has no bin/cache/flutter.version.json and `git describe --tags` fails.".format(checkout))
        version = describe.stdout.strip()

    repository_ctx.file(FRAMEWORK_JSON, json.encode_indent({
        "version": version,
        "commit": commit,
        "dirty": dirty,
        "origin": "local",
        "path": checkout,
    }) + "\n")

flutter_checkout_framework = repository_rule(
    _checkout_framework_impl,
    doc = "A framework source (`flutter_framework.json`, `packages/`, ...) over a flutter/flutter checkout whose path an environment variable gives.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the checkout's path. Set it with `--repo_env`.",
            default = "FLUTTER_CHECKOUT",
        ),
        "checkout": _CHECKOUT_ATTR,
    },
    local = True,
)

def _missing(name, message):
    return "\nflutter_missing_slice(\n    name = {name},\n    message = {message},\n    visibility = [\"//visibility:public\"],\n)\n".format(
        name = json.encode(name),
        message = json.encode(message),
    )

def _dict(d):
    return "{" + ", ".join(['"{}": {}'.format(k, json.encode(v)) for k, v in sorted(d.items())]) + "}"

def _provenance(out_dir, args):
    provenance = {"origin": "out_dir", "out_dir": out_dir, "as_of": "gn"}
    for key in ["engine_version", "content_hash", "dart_version"]:
        if args.get(key):
            provenance[key] = args[key]
    return provenance

def _first_existing(candidates):
    for candidate in candidates:
        if candidate.exists:
            return candidate
    return None

def _gen_snapshot_file(out, cpu):
    """flutter_tools' `_genSnapshotPath`: the first of these directories holding the name."""
    names = ["gen_snapshot_" + cpu, "gen_snapshot"]
    for directory in [".", "universal", "clang_x64", "clang_x86", "clang_i386", "clang_arm64", "clang_riscv64"]:
        base = out if directory == "." else out.get_child(directory)
        found = _first_existing([base.get_child(name) for name in names])
        if found:
            return found
    return None

def _link(repository_ctx, source, destination):
    repository_ctx.symlink(source, destination)
    if source.is_dir:
        repository_ctx.watch_tree(source)
    else:
        repository_ctx.watch(source)

def _engine_out_dirs_impl(repository_ctx):
    path_env = repository_ctx.attr.path_env
    checkout = _checkout_path(repository_ctx, path_env)
    pins = [n.strip() for n in (repository_ctx.getenv(repository_ctx.attr.engines_env) or "").split(",") if n.strip()]
    repository_ctx.file("flutter_engine.json", json.encode_indent({
        "origin": "out_dir",
        "description": "Engine out dirs of a Flutter checkout, built outside Bazel",
    }) + "\n")

    provided = {}  # (package, target) -> BUILD text
    reasons = {}  # (package, target) -> why it is missing
    default_reason = ""
    root_exports = ""
    root_build = ""

    os_name = repository_ctx.os.name.lower()
    arch = "arm64" if repository_ctx.os.arch in ["aarch64", "arm64"] else "x64"
    cpu = "arm64" if arch == "arm64" else "x64"
    host = "darwin-" + arch
    if not checkout:
        default_reason = _unset_message(path_env)
    elif not os_name.startswith("mac"):
        default_reason = "The engine out dirs serve macOS apps built on a Mac so far; this host is " + os_name + "."
    else:
        src = repository_ctx.path(checkout).get_child("engine").get_child("src")
        out_root = src.get_child("out")
        if not out_root.exists:
            fail("{}={} has no engine/src/out: build the engine in it first.".format(path_env, checkout))
        repository_ctx.watch(out_root)

        # Candidates: the directories whose name `tools/gn` could have produced
        # and that hold an args.gn, which says what they are.
        candidates = []
        args_of = {}
        ignored = []
        for entry in out_root.readdir():
            parsed = parse_out_dir_name(entry.basename)
            if parsed == None or not entry.is_dir:
                continue
            args_file = entry.get_child("args.gn")
            if not args_file.exists:
                ignored.append(entry.basename + " (no args.gn)")
                continue
            repository_ctx.watch(args_file)
            args = parse_args_gn(repository_ctx.read(args_file))
            args_of[entry.basename] = args
            candidates.append(struct(
                name = parsed.name,
                os = parsed.os,
                mode = parsed.mode,
                sim = parsed.sim,
                unopt = parsed.unopt,
                cpu = effective_cpu(parsed, args),
            ))
        found = ", ".join([c.name for c in candidates] + ignored) or "nothing"

        def advice(mode):
            return (
                "Found: {found}. Build one in the checkout (engine/src/flutter/tools/gn --runtime-mode {mode} " +
                "--mac-cpu {cpu}, then ninja -C out/host_{mode}_{cpu}), or build in a mode that exists."
            ).format(found = found, mode = mode, cpu = cpu)

        chosen = {}
        for mode in ["debug", "profile", "release"]:
            pick = select_out_dir(candidates, ["host", "mac"], mode, cpu, pins)
            if pick.name:
                chosen[mode] = pick.name
            else:
                message = "The engine out dirs under {out} have no {mode} engine for macOS on {cpu}: {error}. {advice}".format(
                    out = out_root,
                    mode = mode,
                    cpu = cpu,
                    error = pick.error,
                    advice = advice(mode),
                )
                reasons[("macos/" + mode, "engine")] = message
                reasons[(native_target(host) + "/" + mode, "gen_snapshot_" + host)] = message
                if mode == "release":
                    reasons[("kernel/release", "platform")] = message
                if mode == "debug":
                    reasons[("kernel/debug", "platform")] = message
                    reasons[("host/" + host, "tools")] = message

        # The host tools and the debug platform kernel: the host debug out dir,
        # where Flutter builds and archives them.
        if "debug" in chosen:
            tools = src.get_child("out").get_child(chosen["debug"])
            args = args_of[chosen["debug"]]
            prebuilt = args.get("flutter_prebuilt_dart_sdk") == "true"
            prebuilt_host = "macos-" + arch
            dart_sdk = src.get_child("flutter").get_child("prebuilts").get_child(prebuilt_host).get_child("dart-sdk") if prebuilt else tools.get_child("dart-sdk")
            files = {
                "dart-sdk": dart_sdk,
                "host-tools/flutter_tester": tools.get_child("flutter_tester"),
                "host-tools/icudtl.dat": tools.get_child("icudtl.dat"),
                "host-tools/vm_isolate_snapshot.bin": tools.get_child("gen").get_child("flutter").get_child("lib").get_child("snapshot").get_child("vm_isolate_snapshot.bin"),
                "host-tools/isolate_snapshot.bin": tools.get_child("gen").get_child("flutter").get_child("lib").get_child("snapshot").get_child("isolate_snapshot.bin"),
                "host-tools/impellerc": tools.get_child("impellerc"),
                "host-tools/shader_lib": tools.get_child("shader_lib"),
                "host-tools/const_finder.dart.snapshot": tools.get_child("gen").get_child("const_finder.dart.snapshot"),
                "host-tools/font-subset": tools.get_child("font-subset"),
            }
            absent = [dest for dest, source in files.items() if not source.exists]
            if absent:
                reasons[("host/" + host, "tools")] = (
                    "The host debug out dir {out} lacks {absent}: the host tools are built into it by " +
                    "ninja -C out/{name}."
                ).format(out = tools, absent = ", ".join(sorted(absent)), name = chosen["debug"])
            else:
                for dest, source in files.items():
                    _link(repository_ctx, source, dest)
                root_build += """
load("@rules_dart//dart:toolchain.bzl", "dart_sdk_files")

dart_sdk_files(
    name = "dart_sdk",
    prefix = "dart-sdk/",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "shader_lib_files",
    srcs = glob(["host-tools/shader_lib/**"]),
    visibility = ["//visibility:public"],
)
"""
                root_exports = 'exports_files(glob(["**"], exclude = ["BUILD.bazel", "flutter_engine.json"]), visibility = ["//visibility:public"])\n'
                prov = _dict(_provenance(chosen["debug"], args))
                provided[("host/" + host, "tools")] = """
flutter_host_tools(
    name = "tools",
    host_os = "macos",
    host_arch = "{arch}",
    dart_sdk = "//:dart_sdk",
    dart = "//:dart-sdk/bin/dart",
    dartaotruntime = "//:dart-sdk/bin/dartaotruntime",
    frontend_server = "//:dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot",
    kernel_worker = "//:dart-sdk/bin/snapshots/kernel_worker_aot.dart.snapshot",
    dart_libraries_json = "//:dart-sdk/lib/libraries.json",
    dart_platform_dill = "//:dart-sdk/lib/_internal/vm_platform_strong.dill",
    flutter_tester = "//:host-tools/flutter_tester",
    icu_data = "//:host-tools/icudtl.dat",
    vm_isolate_snapshot = "//:host-tools/vm_isolate_snapshot.bin",
    isolate_snapshot = "//:host-tools/isolate_snapshot.bin",
    impellerc = "//:host-tools/impellerc",
    shader_lib = "//:shader_lib_files",
    shader_include_dir = "host-tools/shader_lib",
    const_finder = "//:host-tools/const_finder.dart.snapshot",
    font_subset = "//:host-tools/font-subset",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(arch = arch, prov = prov)

            patched = tools.get_child("flutter_patched_sdk")
            if patched.exists:
                _link(repository_ctx, patched, "kernel/debug/flutter_patched_sdk")
                provided[("kernel/debug", "platform")] = _kernel_stanza("flutter_patched_sdk", _dict(_provenance(chosen["debug"], args)))
            else:
                reasons[("kernel/debug", "platform")] = "The host debug out dir {} has no flutter_patched_sdk.".format(tools)

        # The release (product) platform kernel is the host release out dir's.
        if "release" in chosen:
            release_out = src.get_child("out").get_child(chosen["release"])
            patched = release_out.get_child("flutter_patched_sdk")
            if patched.exists:
                _link(repository_ctx, patched, "kernel/release/flutter_patched_sdk_product")
                provided[("kernel/release", "platform")] = _kernel_stanza("flutter_patched_sdk_product", _dict(_provenance(chosen["release"], args_of[chosen["release"]])))
            else:
                reasons[("kernel/release", "platform")] = "The host release out dir {} has no flutter_patched_sdk.".format(release_out)

        # The macOS engine, and the gen_snapshot of the AOT modes, of each mode's out dir.
        for mode, name in chosen.items():
            out = src.get_child("out").get_child(name)
            args = args_of[name]
            xcframework = out.get_child("FlutterMacOS.xcframework")
            framework = None
            if xcframework.exists:
                for child in xcframework.readdir():
                    if child.basename.startswith("macos-") and child.get_child("FlutterMacOS.framework").exists:
                        framework = child.get_child("FlutterMacOS.framework")
                        break
            if framework == None:
                reasons[("macos/" + mode, "engine")] = "The out dir {} has no FlutterMacOS.xcframework with a macOS slice: build the macOS engine target (ninja -C out/{} flutter/shell/platform/darwin/macos:FlutterMacOS).".format(out, name)
            else:
                _link(repository_ctx, framework, "macos/{}/FlutterMacOS.framework".format(mode))
                provided[("macos/" + mode, "engine")] = """
filegroup(
    name = "files",
    srcs = glob(["FlutterMacOS.framework/**"]),
)

flutter_macos_engine_slice(
    name = "engine",
    mode = "{mode}",
    cpus = ["{engine_cpu}"],
    files = ":files",
    binary = ":FlutterMacOS.framework/Versions/A/FlutterMacOS",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(mode = mode, engine_cpu = "arm64" if cpu == "arm64" else "x86_64", prov = _dict(_provenance(name, args)))
            if mode != "debug":
                gen_snapshot = _gen_snapshot_file(out, cpu)
                target = native_target(host)
                if gen_snapshot == None:
                    reasons[(target + "/" + mode, "gen_snapshot_" + host)] = "The out dir {} has no gen_snapshot_{} (or gen_snapshot) in ., universal or a clang_* directory.".format(out, cpu)
                else:
                    _link(repository_ctx, gen_snapshot, "{}/{}/gen_snapshot".format(target, mode))
                    provided[(target + "/" + mode, "gen_snapshot_" + host)] = """
flutter_gen_snapshot(
    name = "gen_snapshot_{host}",
    binary = ":gen_snapshot",
    target_cpu = "{cpu}",
    mode = "{mode}",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(host = host, cpu = "arm64" if cpu == "arm64" else "x86_64", mode = mode, prov = _dict(_provenance(name, args)))

    # Every slice of the contract is a target: the ones the out dirs provide,
    # and for the rest a missing slice that says why.
    repository_ctx.file("BUILD.bazel", root_build + root_exports + 'exports_files(["flutter_engine.json"], visibility = ["//visibility:public"])\n')
    for package, targets in contract_slices().items():
        content = _ENGINE_LOAD
        for target in targets:
            key = (package, target)
            if key in provided:
                content += provided[key]
            else:
                content += _missing(target, reasons.get(key) or default_reason or (
                    "The engine out dirs provide the macOS slices so far; {} is not one of them.".format(package + ":" + target)
                ))
        repository_ctx.file(package + "/BUILD.bazel", content)

def _kernel_stanza(top, prov):
    return """
filegroup(
    name = "files",
    srcs = glob(["{top}/**"]),
)

flutter_platform_kernel(
    name = "platform",
    platform_dill = "{top}/platform_strong.dill",
    outline_dill = "{top}/vm_outline_strong.dill",
    files = ":files",
    provenance = {prov},
    visibility = ["//visibility:public"],
)
""".format(top = top, prov = prov)

flutter_engine_out_dirs = repository_rule(
    _engine_out_dirs_impl,
    doc = "An engine source (the contract of `@rules_flutter//flutter:engine.bzl`) over the out dirs of a checkout whose path an environment variable gives. macOS slices so far; the others are missing slices that say so.",
    attrs = {
        "path_env": attr.string(
            doc = "The environment variable holding the checkout's path. Set it with `--repo_env`.",
            default = "FLUTTER_CHECKOUT",
        ),
        "engines_env": attr.string(
            doc = "The environment variable naming the out dirs to use, when a slot has more than one candidate.",
            default = "FLUTTER_LOCAL_ENGINES",
        ),
        "checkout": _CHECKOUT_ATTR,
    },
    local = True,
)
