"""`compile_fail_test`: a build that must fail, as a test that passes when it fails as it should.

A target whose build must fail (code `flutter test` refuses, a shader a
required backend cannot compile) cannot be in `bazel test //...` as itself.
This test runs, at test time, the very actions of that target that fail: the
command lines its rule registered, param files included, with their
environment, in a directory laid out as Bazel's execution root over the same
declared inputs, which Bazel builds as this test's runfiles. It passes only
when one of them fails and what the failing ones say holds the expected text,
so it goes red if the build starts succeeding or fails for another reason.

It is Rust's `compile_fail` (the compiler run on code that must not compile,
the test passing on the expected error), over a compile Bazel declared rather
than one the test writes out: a test that ran a different command from the
build's would prove nothing about the build.

Each command is recorded at build time by an action given the target's
action's own `Args`, so Bazel writes its param files as it would for that
action; the record must match `Action.argv`, the action's command line
expanded, or that action fails.
"""

load("@rules_dart//dart:utils.bzl", "runfiles_path")

# Where the inputs of each action sit in this test's runfiles, under the
# action's index, at their exec paths: two inputs of one short path (one built
# for the target, one for a tool) cannot collide there.
_EXECROOT = "compile_fail_execroot"

# With `--experimental_output_paths=strip`, Bazel runs an action that supports
# it with each output path's configuration segment replaced by `cfg`
# (`bazel-out/darwin_arm64-fastbuild/bin/x` is `bazel-out/cfg/bin/x`), in its
# command line, which `Action.argv` shows, and in where its inputs and outputs
# are put.
_MAPPED_ROOT = "bazel-out/cfg/"
_PATH_MAPPING = {"supports-path-mapping": "1"}

_CompileActionsInfo = provider(
    doc = "The actions of a target that run a command, and the tools its attributes name.",
    fields = {
        "actions": "A list of structs: `mnemonic`, `argv`, `args`, `env`, `inputs` (a depset " +
                   "of `File`s) and `outputs` (a list of `File`s).",
        "tools": "A dict from the exec path of each executable the target's attributes name to " +
                 "a struct of its `files_to_run` and `runfiles`.",
    },
)

def _attribute_targets(value):
    if type(value) == "Target":
        return [value]
    if type(value) == "list":
        return [v for v in value if type(v) == "Target"]
    if type(value) == "dict":
        return [v for v in value.keys() + value.values() if type(v) == "Target"]
    return []

# `target.actions` is only an aspect's to read.
def _compile_actions_aspect_impl(target, ctx):
    tools = {}
    for name in dir(ctx.rule.attr):
        for dep in _attribute_targets(getattr(ctx.rule.attr, name)):
            if DefaultInfo not in dep:
                continue
            files_to_run = dep[DefaultInfo].files_to_run
            if files_to_run and files_to_run.executable:
                tools[files_to_run.executable.path] = struct(
                    files_to_run = files_to_run,
                    runfiles = dep[DefaultInfo].default_runfiles,
                )
    return [_CompileActionsInfo(
        actions = [
            struct(
                mnemonic = action.mnemonic,
                argv = action.argv,
                args = action.args,
                env = action.env,
                inputs = action.inputs,
                outputs = action.outputs.to_list(),
            )
            for action in target.actions
            if action.argv
        ],
        tools = tools,
    )]

_compile_actions_aspect = aspect(implementation = _compile_actions_aspect_impl)

def _runfiles_tree(tree, tool, workspace):
    """The files of a tool's runfiles tree, by exec path, as Bazel lays the tree out."""
    files = {
        tree + "/" + runfiles_path(f, workspace): f
        for f in tool.runfiles.files.to_list()
    }
    for entry in tool.runfiles.symlinks.to_list():
        files[tree + "/" + workspace + "/" + entry.path] = entry.target_file
    for entry in tool.runfiles.root_symlinks.to_list():
        files[tree + "/" + entry.path] = entry.target_file
    if tool.files_to_run.repo_mapping_manifest:
        files[tree + "/_repo_mapping"] = tool.files_to_run.repo_mapping_manifest
    return files

def _fail(ctx, action, message):
    fail("%s: %s's %s action %s" % (ctx.label, ctx.attr.target.label, action.mnemonic, message))

def _action_inputs(ctx, action, tools, workspace):
    """The inputs of `action`, by exec path, with each tool's runfiles tree as its files.

    A runfiles tree is an input of an action that runs its tool, and cannot be
    a test's runfile itself; it is laid out from the tool's runfiles instead.
    """
    files = {}
    paths = {f.path: True for f in action.inputs.to_list()}
    for f in action.inputs.to_list():
        stem = f.path.removesuffix(".runfiles")
        if stem != f.path and stem in paths:
            if stem not in tools:
                _fail(ctx, action, "runs %s, whose runfiles tree it cannot lay out: " % stem +
                                   "no attribute of the target names that tool")
            files |= _runfiles_tree(f.path, tools[stem], workspace)
        else:
            files[f.path] = f
    return files

def _maps_paths(action):
    return bool([arg for arg in action.argv if _MAPPED_ROOT in arg])

def _path_mapper(action):
    if not _maps_paths(action):
        return lambda path: path
    return lambda path: _MAPPED_ROOT + path.split("/", 2)[2] if path.startswith("bazel-out/") else path

def _mapped(ctx, action, files, map_path):
    mapped = {}
    for path, f in files.items():
        to = map_path(path)
        if to in mapped:
            _fail(ctx, action, "has two inputs at %s once output paths are stripped" % to)
        mapped[to] = f
    return mapped

def _compile_fail_test_impl(ctx):
    info = ctx.attr.target[_CompileActionsInfo]
    actions = [action for action in info.actions if action.mnemonic in ctx.attr.mnemonics]
    if not actions:
        fail("%s: %s registers no action of %s" % (ctx.label, ctx.attr.target.label, ctx.attr.mnemonics))

    workspace = ctx.workspace_name
    described = []
    records = []
    root_symlinks = {}
    for index, action in enumerate(actions):
        expected = ctx.actions.declare_file("%s.%d.argv.json" % (ctx.label.name, index))
        ctx.actions.write(expected, json.encode(action.argv))
        record = ctx.actions.declare_file("%s.%d.command.json" % (ctx.label.name, index))
        own = ctx.actions.args()
        own.add(record)
        own.add(expected)
        ctx.actions.run(
            executable = ctx.executable._command,
            arguments = [own] + action.args,
            inputs = [expected],
            outputs = [record],
            mnemonic = "CompileFailCommand",
            progress_message = "Recording the %s command of %s" % (action.mnemonic, ctx.attr.target.label),
            execution_requirements = _PATH_MAPPING if _maps_paths(action) else {},
        )
        records.append(record)

        map_path = _path_mapper(action)
        inputs = _mapped(ctx, action, _action_inputs(ctx, action, info.tools, workspace), map_path)
        execroot = "%s/%d" % (_EXECROOT, index)
        root_symlinks |= {execroot + "/" + path: f for path, f in inputs.items()}
        described.append({
            "mnemonic": action.mnemonic,
            "command": runfiles_path(record, workspace),
            "env": action.env,
            "execroot": execroot,
            "inputs": sorted(inputs.keys()),
            "outputs": [{"path": map_path(f.path), "directory": f.is_directory} for f in action.outputs],
        })

    config = ctx.actions.declare_file(ctx.label.name + ".compile_fail.json")
    ctx.actions.write(config, json.encode({
        "actions": described,
        "outputContains": ctx.attr.output_contains,
    }))

    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._runner,
        is_executable = True,
    )
    runfiles = ctx.runfiles(
        files = [config] + records,
        root_symlinks = root_symlinks,
    ).merge(ctx.attr._runner[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = {
            "COMPILE_FAIL_CONFIG": runfiles_path(config, workspace),
        }),
    ]

compile_fail_test = rule(
    implementation = _compile_fail_test_impl,
    attrs = {
        "target": attr.label(
            doc = "The target whose build must fail: its own actions, not its dependencies', " +
                  "are the ones searched. It is `manual`, since building it fails.",
            mandatory = True,
            aspects = [_compile_actions_aspect],
        ),
        "mnemonics": attr.string_list(
            doc = "The mnemonics of the actions to run: every action of `target` with one of " +
                  "them runs. More than one where flags choose the compile: a " +
                  "`flutter_test_program` compiles its entry point in `DartEntryKernel` in the " +
                  "modular build and its whole program in `DartKernel` with " +
                  "`--@rules_dart//dart:modular_kernel=false`.",
            mandatory = True,
            allow_empty = False,
        ),
        "output_contains": attr.string_list(
            doc = "Text the output of the failing actions must contain.",
            mandatory = True,
            allow_empty = False,
        ),
        "_command": attr.label(
            default = Label("//tools/e2e_testing:compile_fail_command"),
            executable = True,
            cfg = "exec",
        ),
        "_runner": attr.label(
            default = Label("//tools/e2e_testing:compile_fail_runner"),
            executable = True,
            cfg = "target",
        ),
    },
    test = True,
    doc = """Runs the actions of `target` named by `mnemonics`, as its build would, and passes \
when at least one fails and the failing ones' output contains every `output_contains`.

The actions run where the test runs, so the target's execution platform must be \
the test's: a host compile, as Dart kernel and shader compiles are.""",
)
