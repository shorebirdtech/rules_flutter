"""What a Flutter program rule hands rules_dart's analysis: its own Dart files.

A program (`flutter_application`, `flutter_application_variant`,
`flutter_test`, `flutter_web_application`) is a bundle, not a library, so no
`DartInfo` names its files. `program_analyzable_info` is the one place each
of them says which files are its own, and `StagedSourcesInfo` is how a rule
that stages copies of source files into a program names the sources.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_analyzable_info", "package_info_from_metadata", "package_lib_prefix")

StagedSourcesInfo = provider(
    doc = "The source files a target's Dart outputs are copies of. A program " +
          "compiles the copies, and analysis checks these in their place: " +
          "analysis checks no generated file.",
    fields = {
        "sources": "Depset of source Files, each staged under the same basename beside its siblings, so their relative imports resolve alike.",
    },
)

BundledProgramInfo = provider(
    doc = "The program a part of a platform's app bundle is built from, for " +
          "the app to pass on to rules_dart's analysis when the bundle rule " +
          "(rules_apple's) passes on nothing of its contents'.",
    fields = {
        "info": "The program's `DartAnalyzableInfo`.",
    },
)

def bundled_program_info(application):
    """The `BundledProgramInfo` of a bundle part built from `application`, if it is a program.

    Args:
      application: The part's `flutter_application` (or variant) Target.

    Returns:
      A list of one `BundledProgramInfo`, or none.
    """
    if DartAnalyzableInfo not in application:
        return []
    return [BundledProgramInfo(info = application[DartAnalyzableInfo])]

def _bundled_program_aspect_impl(_target, ctx):
    # The parts of the bundle, as the bundle rule configured them, so the
    # program found is the one the app ships. Each part that has one names the
    # same application.
    attrs = ctx.rule.attr
    parts = list(getattr(attrs, "deps", [])) + list(getattr(attrs, "additional_contents", {}).keys())
    for part in parts:
        if BundledProgramInfo in part:
            return [part[BundledProgramInfo]]
    return []

# Applied to an Apple bundle alone, without propagating: it reads the
# `BundledProgramInfo` of the bundle's direct parts.
bundled_program_aspect = aspect(
    implementation = _bundled_program_aspect_impl,
    doc = "Finds the program among an app bundle's direct parts (`deps`, `additional_contents`).",
)

# Analysis-only. `package:sky_engine`'s `lib/_embedder.yaml` is the whole of how
# the analyzer resolves `dart:ui`. An implicit attribute, because needing it is
# a property of analyzing Flutter Dart, not a choice a BUILD file makes; it
# reaches only `program_analyzable_info`, so no compile action's inputs change.
PROGRAM_SKY_ENGINE_ATTR = attr.label(
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

def staged_sources(targets):
    """The sources `targets` staged copies of, from their `StagedSourcesInfo`.

    Args:
      targets: Targets, some of which may provide `StagedSourcesInfo`.

    Returns:
      A list of source Files.
    """
    return depset(transitive = [
        t[StagedSourcesInfo].sources
        for t in targets
        if StagedSourcesInfo in t
    ]).to_list()

def program_analyzable_info(ctx, package, package_root, deps, files):
    """The `DartAnalyzableInfo` of a program in `package`, over its own `files`.

    Built by `dart_analyzable_info` rather than the package-less constructor:
    a program names its package, and its sources import that package's `lib/`
    by `package:<self>/…`, which a package-less closure reports as
    `uri_does_not_exist`. `package_root` is the root the compile path names,
    so the analyzer and the compiler agree on what `package:<self>/…` is.

    Files are split by path. One under the package's `lib/` is reachable as
    `package:<self>/…` and is among `srcs`; any other (a `test/` or
    `integration_test/` entry point, a `main` beside `web/`, a staged file) is
    an entry source. Generated files may be among them: analysis stages them
    for imports to resolve and checks only sources.

    Args:
      ctx: The rule context. Reads `_sky_engine` (`PROGRAM_SKY_ENGINE_ATTR`),
        which joins the analyzer's closure and nothing else.
      package: The program's `DartPackageMetadataInfo`.
      package_root: The package's root, as the compile path takes it.
      deps: The program's dependencies, providing `DartInfo`.
      files: The program's own Dart files: its `main`, its sources, and the
        sources of whatever it compiles copies of.

    Returns:
      A `DartAnalyzableInfo`.
    """
    prefix = package_lib_prefix(package_root)
    return dart_analyzable_info(
        label = ctx.label,
        # The declaration the compile path names, so the analyzer reads the
        # language version the compiler does.
        packages = [package_info_from_metadata(ctx.label, package, package_root)],
        deps = deps + [ctx.attr._sky_engine],
        srcs = [f for f in files if f.short_path.startswith(prefix)],
        entry_srcs = [f for f in files if not f.short_path.startswith(prefix)],
    )
