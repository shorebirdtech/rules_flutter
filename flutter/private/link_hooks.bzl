"""The data assets a program ships, through its packages' link hooks or not.

Native and web applications choose them the same way, as `flutter build`
does for every target: in a release or profile build every package with a
`hook/link.dart` has it run over the uses the compiler recorded, and a hook
receives its own package's declared data assets and decides which ship; a
debug build runs no hook and ships every package's declared assets. What
differs between targets is only which compile records the uses.
"""

load("@rules_dart//dart:utils.bzl", "collect_transitive_data_assets", "dart_link_hook_actions", "program_packages")
load("//flutter/private:common.bzl", "program_package", "program_package_files")

def link_hooks_plan(program, deps, links):
    """Whether a program's link hooks run, decided before its compile.

    The compile that records the uses has to be told to, so this is asked
    first, and `program_data_assets` takes the answer after.

    Every package of the program counts, its own among them: a link hook
    of the app's package runs whether or not a library of that package is
    in `deps`, as upstream's hooks runner plans the root package with the
    rest.

    Args:
        program: The program, from `flutter_program_inputs`.
        deps: The `deps` whose closure is linked (a web branch's, on web).
        links: Whether the build mode links: not a debug build.

    Returns:
        A struct: `runs` (bool: the compile records uses and the hooks run
        over them).
    """
    return struct(
        runs = links and (bool(program.link_hook_assets) or any([
            getattr(pkg, "link_hook", None) != None
            for pkg in program_packages(program_package(program), deps)
        ])),
    )

def program_data_assets(ctx, program, deps, plan, recorded_uses, name):
    """The data assets a program ships.

    Linked, they are what the package link hooks emit over `recorded_uses`
    (the ids in `link_hook_assets`) and the declared assets of packages
    without a hook; unlinked, every package's declared assets. The program's
    own package is one of its packages either way.

    Args:
        ctx: Rule context carrying `link_hook_runner_attr()`, the
            `COPY_TO_DIRECTORY_TOOLCHAINS` and `PORTABLE_EXEC_GROUPS`.
        program: The program, from `flutter_program_inputs`.
        deps: The `deps` whose closure is linked, as given to `link_hooks_plan`.
        plan: What `link_hooks_plan` returned.
        recorded_uses: The recorded-uses JSON File when `plan.runs`, else None.
        name: Prefix for the link outputs, unique within the package.

    Returns:
        A struct: `assets` (depset of data-asset structs, as
        `DartDataAssetInfo` carries) and `validation_outputs` (Files for an
        `_validation` output group, so every hook runs whenever the target
        builds, even one that emits nothing).
    """
    if not plan.runs:
        return struct(
            assets = depset(collect_transitive_data_assets(program_package(program), deps)),
            validation_outputs = [],
        )
    link = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        recorded_uses = recorded_uses,
        package = program_package(program),
        package_files = program_package_files(program),
        deps = deps,
        data_asset_ids = program.link_hook_assets,
        name = name,
    )
    return struct(
        assets = depset(link.assets),
        validation_outputs = link.validation_outputs,
    )
