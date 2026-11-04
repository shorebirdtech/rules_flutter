"""Actions that run Xcode's tools on an Apple target's AOT snapshot.

Shared by the iOS and macOS framework rules: both ship gen_snapshot's Mach-O
dylib as `App.framework/App`, and both treat it the way `flutter build`
does (`flutter_tools/lib/src/base/build.dart`): the dSYM is extracted from the
snapshot with `dsymutil`, and then `strip -x` removes the local symbols the
shipped binary does not need.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "use_cc_toolchain")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")

# The attributes and toolchains a rule needs to call `run_xcode_tool`.
XCODE_TOOL_ATTRS = dicts.add(
    apple_support.action_required_attrs(),
    apple_support.platform_constraint_attrs(),
)
XCODE_TOOL_TOOLCHAINS = use_cc_toolchain(mandatory = True)
XCODE_TOOL_FRAGMENTS = ["apple"]

def run_xcode_tool(ctx, **kwargs):
    """Registers a shell action that runs Xcode's tools (`xcrun`).

    `apple_support.run_shell` gives the action the selected Xcode's
    environment (`DEVELOPER_DIR`, `SDKROOT`) and execution requirements, so the
    Xcode version is part of the action's key. The workspace's shell
    environment is left out: an `--action_env` such as
    `MACOSX_DEPLOYMENT_TARGET` would otherwise retarget clang. The action runs
    in the auto exec group of the C++ toolchain resolved for this Apple target:
    that toolchain is Xcode's clang, and its registration says which hosts can
    run Xcode.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`, `XCODE_TOOL_FRAGMENTS` and
        `XCODE_TOOL_TOOLCHAINS`.
      **kwargs: Forwarded to `ctx.actions.run_shell`.
    """
    apple_support.run_shell(
        actions = ctx.actions,
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
        apple_platform_info = apple_support.platform_info_from_rule_ctx(ctx),
        toolchain = CC_TOOLCHAIN_TYPE,
        use_default_shell_env = False,
        **kwargs
    )

def declare_dsym(ctx, directory):
    """Declares the files of an `App.framework.dSYM` bundle.

    The bundle is declared as the two files `dsymutil` writes into it, not as
    a tree artifact, because that is the form rules_apple takes a framework's
    `dsym_imports` in.

    Args:
      ctx: A rule context.
      directory: The package-relative directory the bundle is declared in.

    Returns:
      A struct of `plist`, `dwarf` and `files`.
    """
    bundle = "%s/App.framework.dSYM" % directory
    plist = ctx.actions.declare_file(bundle + "/Contents/Info.plist")
    dwarf = ctx.actions.declare_file(bundle + "/Contents/Resources/DWARF/App")
    return struct(plist = plist, dwarf = dwarf, files = [plist, dwarf])

def split_and_strip_aot_binary(
        ctx,
        dylib,
        object,
        binary,
        dsym,
        retag = None):
    """Registers the action that makes the shipped `App` and its dSYM.

    Order matters: the dSYM is read out of the snapshot before `strip -x`
    removes what it is read from. `dsymutil` follows the snapshot's debugging
    map to `object`, the relocatable object gen_snapshot wrote beside it, so
    that has to be an input at the path gen_snapshot recorded.

    The binary's UUID is the same before and after, so crash reports of the
    shipped binary symbolicate against the dSYM.

    Args:
      ctx: A rule context with `XCODE_TOOL_ATTRS`.
      dylib: gen_snapshot's dylib, symbols intact.
      object: The relocatable object gen_snapshot wrote with it.
      binary: The `App` File to write.
      dsym: A `declare_dsym` struct.
      retag: None, or a pair of the `vtool` platform and the minimum OS
        version to tag the binary with, for a dylib gen_snapshot tagged as
        macOS (the host it ran on) that is for another platform.
    """
    if object == None:
        fail(
            ("%s: the application provides no gen_snapshot object, so no " +
             "dSYM can be extracted from its snapshot. It is produced by a " +
             "flutter_application built for an Apple platform in release or " +
             "profile mode.") % ctx.label,
        )
    args = ctx.actions.args().add_all([dylib, binary, dsym.plist])
    commands = [
        "set -e",
        'cp "$1" "$2"',
        # An input is read-only, and so is this copy of it.
        'chmod u+w "$2"',
        # Run on the copy: the DWARF file in the bundle is named for the file
        # it is read from, and it is `App`.
        'xcrun dsymutil -o "$(dirname "$(dirname "$3")")" "$2"',
    ]
    if retag:
        args.add_all(retag)
        commands.append('xcrun vtool -set-build-version "$4" "$5" "$5" -replace -output "$2" "$2"')
    commands.append('xcrun strip -x "$2" -o "$2"')
    run_xcode_tool(
        ctx,
        command = "\n".join(commands),
        arguments = [args],
        inputs = [dylib, object],
        outputs = [binary] + dsym.files,
        mnemonic = "FlutterAppleSplitDebugInfo",
        execution_requirements = PATH_MAPPING,
        progress_message = "Extracting the dSYM of and stripping %s" % binary.short_path,
    )
