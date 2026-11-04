"""Flutter asset bundle generation.

Produces a `flutter_assets/` tree artifact containing:
- AssetManifest.bin  (StandardMessageCodec binary manifest)
- FontManifest.json  (font family declarations)
- NOTICES.Z          (gzip-compressed license text)
- Copied asset files (images, etc.)
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:asset_variants.bzl", "variant_scale")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions", "package_relative")
load("//flutter/private:path_mapping.bzl", "file_ref", "json_config_args")

_TOOL = Label("//flutter/private/tools:generate_asset_manifest.dart")

def detect_dpr(path):
    """Detect the device pixel ratio from the directory a file is in.

    A file is a resolution variant of the file of the same name one directory
    up when its immediate parent directory is named for a scale (`2x`, `1.5x`,
    `0.75x`; see `variant_scale`). A directory further up, or below, makes no
    variant of it.

    Args:
        path: Asset path string (e.g. "assets/2.0x/icon.png").

    Returns:
        (base_path, dpr) tuple.  base_path has the DPR dir removed (e.g.
        "assets/icon.png").  dpr is a float or None if not a variant.
    """
    parts = path.split("/")
    if len(parts) >= 2:
        dpr = variant_scale(parts[-2])
        if dpr != None:
            return "/".join(parts[:-2] + parts[-1:]), dpr
    return path, None

def build_asset_manifest(assets):
    """Build the asset manifest structure from a list of asset paths.

    Args:
        assets: list of asset path strings relative to package root.

    Returns:
        dict mapping logical key → list of variant dicts.
    """
    manifest = {}

    # Group by base path.
    for path in sorted(assets):
        base, dpr = detect_dpr(path)
        if base not in manifest:
            manifest[base] = []
        entry = {"asset": path}
        if dpr != None:
            entry["dpr"] = dpr
        manifest[base].append(entry)

    # Ensure the main (1x) variant is first in each list.
    for base in manifest:
        variants = manifest[base]
        main_idx = None
        for i, v in enumerate(variants):
            if v["asset"] == base:
                main_idx = i
                break
        if main_idx != None and main_idx != 0:
            main = variants.pop(main_idx)
            variants.insert(0, main)

    return manifest

def flutter_asset_bundle_action(
        ctx,
        dart,
        flutter_sdk_files,
        assets = [],
        fonts = [],
        notices = "",
        license_files = [],
        output_dir = None,
        const_finder = None,
        font_subset = None,
        kernel_dill = None,
        optional_code_points = [],
        extra_asset_copies = {}):
    """Create an action that generates the flutter_assets/ tree artifact.

    Args:
        ctx: Rule context.
        dart: The `dart` executable File from the Flutter SDK.
        flutter_sdk_files: SDK files needed to run dart (for action inputs).
        assets: list of File objects of the target's package to include in the
            bundle, each under its path in that package (`assets/a.png`).
        fonts: list of font declaration dicts (FontManifest.json schema).
        notices: License text string to compress into NOTICES.Z.
        license_files: list of File objects containing license text to include in NOTICES.Z.
        output_dir: The already-declared directory (tree artifact) File to
            write the bundle into. Declared by the caller rather than here
            because an application has to know where its assets will land
            *before* this action runs — the path is baked into the app as
            `rules_flutter.build_info.assetsDir`, which the dev tool matches
            against the tree it watches and rebuilds. Declaring an output and
            registering the action that fills it are separate steps in
            Starlark, so hoisting the declaration introduces no cycle even
            though icon tree shaking makes this action depend on the kernel.
        const_finder: File for const_finder.dart.snapshot (enables icon tree shaking).
        font_subset: File for font-subset binary (enables icon tree shaking).
        kernel_dill: File for the compiled kernel .dill (needed for icon tree shaking).
        optional_code_points: Code points every subset icon font keeps if the
            font has a glyph for them, used or not (`optional:<n>` to
            font-subset).
        extra_asset_copies: dict mapping custom dest path → File for assets that
            need a specific destination path (e.g. "fonts/MaterialIcons-Regular.otf").

    Returns:
        The `output_dir` it was given, so callers can chain.
    """
    if output_dir == None:
        fail("flutter_asset_bundle_action: `output_dir` is required — declare it with ctx.actions.declare_directory().")
    tool = ctx.file._asset_bundle_tool

    # Every path in the config is a `file_ref`, which Bazel fills in when it
    # writes the config, path-mapped where the action is.
    refs = []

    # Build asset paths and copy map relative to the output directory.
    asset_paths = []
    copies = {}
    for f in assets:
        key = package_relative(ctx, f)
        asset_paths.append(key)
        copies[key] = file_ref(refs, f)

    # Add extra copies with custom destination paths.
    extra_files = []
    for dest_path, f in extra_asset_copies.items():
        asset_paths.append(dest_path)
        copies[dest_path] = file_ref(refs, f)
        extra_files.append(f)

    # Build manifest structure.
    manifest = build_asset_manifest(asset_paths)

    # Write the config JSON.
    config = {
        "assets": manifest,
        "fonts": fonts,
        "copies": copies,
        "notices": notices,
        "license_files": [file_ref(refs, f) for f in license_files],
    }

    # Icon tree shaking config.
    extra_inputs = []
    if const_finder and font_subset and kernel_dill:
        config["icon_tree_shaking"] = {
            "dart": file_ref(refs, dart),
            "const_finder": file_ref(refs, const_finder),
            "font_subset": file_ref(refs, font_subset),
            "kernel_dill": file_ref(refs, kernel_dill),
            "optional_code_points": optional_code_points,
        }
        extra_inputs.extend([const_finder, font_subset, kernel_dill])

    args = ctx.actions.args()
    args.add(tool)
    args.add_all("--output-dir", [output_dir], expand_directories = False)
    args.add("--config")

    ctx.actions.run(
        executable = dart,
        arguments = [args, json_config_args(ctx, config, refs)],
        inputs = depset(
            direct = [tool] + assets + extra_files + license_files + extra_inputs,
            transitive = [flutter_sdk_files],
        ),
        outputs = [output_dir],
        mnemonic = "FlutterAssetBundle",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Bundling Flutter assets %s" % ctx.label,
    )

    return output_dir

def _flutter_asset_bundle_impl(ctx):
    tools = portable_tools(ctx)

    # Walk pub-package font/asset contributions from FlutterInfo. To get
    # MaterialIcons in the bundle, list `@rules_flutter//flutter:material_icons`
    # in deps — the same channel cupertino_icons et al. arrive through.
    fonts, extra_asset_copies = aggregate_pub_contributions(ctx.attr.deps)

    output_dir = flutter_asset_bundle_action(
        ctx = ctx,
        dart = tools.dart,
        flutter_sdk_files = tools.tool_files,
        assets = ctx.files.assets,
        fonts = fonts,
        notices = "",
        output_dir = ctx.actions.declare_directory(ctx.label.name),
        extra_asset_copies = extra_asset_copies,
    )

    return [DefaultInfo(files = depset([output_dir]))]

flutter_asset_bundle = rule(
    implementation = _flutter_asset_bundle_impl,
    attrs = {
        "assets": attr.label_list(
            doc = "Asset files to include in the bundle.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "Flutter library dependencies whose assets to include.",
        ),
        "_asset_bundle_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Generates a flutter_assets/ tree artifact with manifests and asset files.",
)
