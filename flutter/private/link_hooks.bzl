"""The data assets a program ships, through its packages' link hooks or not.

Native and web applications choose them the same way, as `flutter build`
does for every target: in a release or profile build every package with a
`hook/link.dart` has it run over the uses the compiler recorded, and a hook
receives its own package's declared data assets and decides which ship; a
debug build runs no hook and ships every package's declared assets. What
differs between targets is only which compile records the uses.
"""

load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_data_assets", "dart_link_hook_actions")
load("//flutter/private:common.bzl", "own_package_outside_deps")

def link_hooks_plan(ctx, program, deps, links):
    """Whether a program's link hooks run, decided before its compile.

    The compile that records the uses has to be told to, so this is asked
    first, and `program_data_assets` takes the answer after.

    Args:
        ctx: Rule context, for messages.
        program: The program, from `flutter_program_inputs`.
        deps: The `deps` whose closure is linked (a web branch's, on web).
        links: Whether the build mode links: not a debug build.

    Returns:
        A struct: `runs` (bool: the compile records uses and the hooks run
        over them) and `own_data_assets` (the declared data assets of the
        program's own package when no library in `deps` carries it).
    """
    packages = collect_packages(deps)
    own = own_package_outside_deps(program, packages)
    if links and own != None and own.link_hook != None:
        fail(("%s: the package `%s` has a link hook, which runs only for a " +
              "package a library in `deps` belongs to. Move the package's " +
              "`lib/` sources into a `flutter_library` naming `%s`.") %
             (ctx.label, own.package_name, own.label))
    return struct(
        runs = links and (bool(program.link_hook_assets) or any([
            getattr(pkg, "link_hook", None) != None
            for pkg in packages
        ])),
        own_data_assets = list(own.data_assets) if own != None else [],
    )

def program_data_assets(ctx, program, deps, plan, recorded_uses, name):
    """The data assets a program ships.

    Linked, they are what the package link hooks emit over `recorded_uses`
    (the ids in `link_hook_assets`) and the declared assets of packages
    without a hook; unlinked, every package's declared assets. The program's
    own package's declared assets ship either way.

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
            assets = depset(collect_transitive_data_assets(deps) + plan.own_data_assets),
            validation_outputs = [],
        )
    link = dart_link_hook_actions(
        ctx,
        runner = ctx.executable._link_hook_runner,
        recorded_uses = recorded_uses,
        deps = deps,
        data_asset_ids = program.link_hook_assets,
        name = name,
    )
    return struct(
        assets = depset(link.assets + plan.own_data_assets),
        validation_outputs = link.validation_outputs,
    )
