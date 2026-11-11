"""Tests for `flutter_application_variant`: an application rebuilt with another `main`.

Over `//flutter/tests/variant_fixture`: an application with a source, an asset
and a plugin, a variant in another Bazel package (its own `main`, a source, a
plugin, a define) and a variant whose `main` is in the application's own
`lib/`. Each test says in plain words what it holds the variant to.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load(":action_content.bzl", "action_config", "package_entry", "written_json")
load(":version_defines_test.bzl", "pinned_version_defines")

_APP = "//flutter/tests/variant_fixture/app:app"
_PACKAGE = "variant_app"

_DBG = {"//command_line_option:compilation_mode": "dbg"}

def _kernel(env):
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernels), "expected one DartKernel")
    return kernels[0] if kernels else None

def _input_basenames(action):
    return sorted([f.basename for f in action.inputs.to_list()])

# -- The program it compiles ---------------------------------------------------

def _compiles_given_main_impl(ctx):
    """The variant compiles the `main` it was given, and keeps the application's as a source."""
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)

    # The entrypoint is the compiler's last argument.
    asserts.equals(env, ctx.attr.entrypoint, kernel.argv[-1])
    inputs = _input_basenames(kernel)
    asserts.true(env, ctx.attr.main in inputs, "the given main %s is compiled: %s" % (ctx.attr.main, inputs))
    asserts.true(
        env,
        "main.dart" in inputs,
        "the application's own main.dart stays a source, for the new main to import: %s" % inputs,
    )
    return analysistest.end(env)

_compiles_given_main_test = analysistest.make(
    _compiles_given_main_impl,
    attrs = {
        "entrypoint": attr.string(mandatory = True),
        "main": attr.string(mandatory = True),
    },
    config_settings = _DBG,
)

def _kernel_inputs_impl(ctx):
    """The variant's compile reads the application's sources and its own."""
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    inputs = _input_basenames(kernel)
    for name in ["helper.dart", "extra.dart", "base_plugin.dart", "extra_plugin.dart"]:
        asserts.true(env, name in inputs, "%s is a kernel input of the variant: %s" % (name, inputs))
    return analysistest.end(env)

_kernel_inputs_test = analysistest.make(_kernel_inputs_impl, config_settings = _DBG)

def _plugins_impl(ctx):
    """The plugins an app registers are those its own dependencies bring."""
    env = analysistest.begin(ctx)
    plugins = analysistest.target_under_test(env)[FlutterApplicationInfo].plugins
    asserts.equals(env, ctx.attr.expected, sorted([p.name for p in plugins]))
    return analysistest.end(env)

_plugins_test = analysistest.make(
    _plugins_impl,
    attrs = {"expected": attr.string_list()},
    config_settings = _DBG,
)

def _defines_impl(ctx):
    """The variant's `defines` follow the application's, and reach the compile."""
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    asserts.true(env, "-DVARIANT=1" in kernel.argv, "the variant's define reaches the compiler: %s" % kernel.argv)
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(env, ["VARIANT=1"] + pinned_version_defines(), config["dartDefines"])
    return analysistest.end(env)

_defines_test = analysistest.make(_defines_impl, config_settings = _DBG)

def _flavor_impl(ctx):
    """A variant of a flavored application is that flavor: `appFlavor` in the app, and in the dev loop's replay."""
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    asserts.true(env, "-DFLUTTER_APP_FLAVOR=paid" in kernel.argv, "the application's flavor reaches the variant's compile: %s" % kernel.argv)
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(env, ["FLUTTER_APP_FLAVOR=paid"] + pinned_version_defines(), config["dartDefines"])
    return analysistest.end(env)

_flavor_test = analysistest.make(_flavor_impl, config_settings = _DBG)

# -- The application's package -------------------------------------------------

def _package_impl(ctx):
    """A variant is in its application's Dart package, wherever its own target is."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".package_config.json")
    if config == None:
        return analysistest.end(env)
    entry = package_entry(config, _PACKAGE)
    asserts.true(env, entry != None, "the program's package is the application's %s: %s" % (_PACKAGE, config["packages"]))
    if entry != None:
        # Rooted at the application's own directory, not the variant's.
        asserts.true(
            env,
            entry["rootUri"].rstrip("/").endswith("flutter/tests/variant_fixture/app"),
            "%s resolves against the application's package, got %s" % (_PACKAGE, entry["rootUri"]),
        )
    return analysistest.end(env)

_package_test = analysistest.make(_package_impl, config_settings = _DBG)

def _in_package_main_impl(ctx):
    """A variant `main` under the application's `lib/` is `package:<application's name>/…`."""
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    asserts.equals(env, "package:%s/variant_main.dart" % _PACKAGE, kernel.argv[-1])
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(env, "package:%s/variant_main.dart" % _PACKAGE, config["appEntrypoint"])
    return analysistest.end(env)

_in_package_main_test = analysistest.make(_in_package_main_impl, config_settings = _DBG)

def _assets_impl(ctx):
    """The application's assets are bundled under their keys in its package, from a variant elsewhere."""
    env = analysistest.begin(ctx)
    config = action_config(env, "FlutterAssetBundle")
    if config == None:
        return analysistest.end(env)
    asserts.true(env, "assets/a.txt" in config["copies"], "the asset keeps its key in the application's package: %s" % config["copies"].keys())
    return analysistest.end(env)

_assets_test = analysistest.make(_assets_impl, config_settings = _DBG)

# -- What the dev loop is told ---------------------------------------------------

def _dev_config_impl(ctx):
    """A variant tells the dev tool about its own entry point, outside the package's `lib/`."""
    env = analysistest.begin(ctx)
    config = written_json(env, "_dev_config.json")
    if config == None:
        return analysistest.end(env)
    asserts.equals(
        env,
        "org-dartlang-app:///flutter/tests/variant_fixture/other/variant_main.dart",
        config["appEntrypoint"],
    )
    asserts.equals(
        env,
        [
            "flutter/tests/variant_fixture/other/variant_main.dart",
            "flutter/tests/variant_fixture/other/extra.dart",
        ],
        [s["path"] for s in config["appSources"]],
    )
    return analysistest.end(env)

_dev_config_test = analysistest.make(_dev_config_impl, config_settings = _DBG)

def _generated_main_impl(ctx):
    """A `main` a rule wrote, beside the source it imports, is compiled from both their roots."""
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    argv = kernel.argv
    asserts.equals(
        env,
        "org-dartlang-app:///flutter/tests/variant_fixture/other/generated_main.dart",
        argv[-1],
    )

    # The generated `main` is in the output directory and `extra.dart` in the
    # exec root, and the compiler finds each under its own root.
    roots = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--filesystem-root"]
    asserts.true(env, "." in roots, "the exec root, where the source is, is mounted: %s" % roots)
    asserts.true(
        env,
        [r for r in roots if r.startswith("bazel-out/") and r.endswith("/bin")] != [],
        "the output directory, where the generated main is, is mounted: %s" % roots,
    )

    # What is checked against the program's deps is the user's source, and not
    # the file the rule wrote.
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]
    asserts.equals(env, 1, len(checks), "one import check")
    if checks:
        checked = " ".join(checks[0].argv)
        asserts.true(env, "extra.dart" in checked, "the user's source is checked: %s" % checked)
        asserts.false(env, "generated_main.dart" in checked, "the rule's own file is not: %s" % checked)
    return analysistest.end(env)

_generated_main_test = analysistest.make(_generated_main_impl, config_settings = _DBG)

def _code_asset_impl(ctx):
    """A variant of an app with a code asset bundles it, with what its build declared."""
    env = analysistest.begin(ctx)
    config = written_json(env, "_dev_config.json")
    if config == None:
        return analysistest.end(env)
    libs = config["nativeLibs"]
    asserts.equals(env, 1, len(libs), "the variant bundles the application's one library: %s" % libs)
    if len(libs) != 1:
        return analysistest.end(env)
    asserts.equals(
        env,
        ["interface.json"],
        sorted([p.rsplit("/", 1)[-1] for p in config["nativeLibContracts"][libs[0]]]),
    )
    return analysistest.end(env)

_code_asset_test = analysistest.make(_code_asset_impl, config_settings = _DBG)

def flutter_application_variant_test_suite(name):
    """Tests of `flutter_application_variant` over `//flutter/tests/variant_fixture`.

    Args:
        name: The test suite name.
    """
    elsewhere = "//flutter/tests/variant_fixture/other:elsewhere"
    in_package = "//flutter/tests/variant_fixture/app:in_package"
    _compiles_given_main_test(
        name = name + "_compiles_given_main",
        target_under_test = elsewhere,
        entrypoint = "org-dartlang-app:///flutter/tests/variant_fixture/other/variant_main.dart",
        main = "variant_main.dart",
    )
    _kernel_inputs_test(name = name + "_kernel_inputs", target_under_test = elsewhere)
    _plugins_test(
        name = name + "_plugins_in_variant",
        target_under_test = elsewhere,
        expected = ["variant_base_plugin", "variant_extra_plugin"],
    )
    _plugins_test(
        name = name + "_plugins_in_application",
        target_under_test = _APP,
        expected = ["variant_base_plugin"],
    )
    _defines_test(name = name + "_defines", target_under_test = elsewhere)
    _flavor_test(
        name = name + "_flavor",
        target_under_test = "//flutter/tests/variant_fixture/other:flavored",
    )
    _package_test(name = name + "_package", target_under_test = elsewhere)
    _in_package_main_test(name = name + "_in_package_main", target_under_test = in_package)
    _assets_test(name = name + "_assets", target_under_test = elsewhere)
    _dev_config_test(name = name + "_dev_config", target_under_test = elsewhere)
    _generated_main_test(
        name = name + "_generated_main",
        target_under_test = "//flutter/tests/variant_fixture/other:generated",
    )
    _code_asset_test(
        name = name + "_code_asset",
        target_under_test = "//flutter/tests/code_asset_fixture:variant_dart_owner",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_compiles_given_main",
            ":" + name + "_kernel_inputs",
            ":" + name + "_plugins_in_variant",
            ":" + name + "_plugins_in_application",
            ":" + name + "_defines",
            ":" + name + "_flavor",
            ":" + name + "_package",
            ":" + name + "_in_package_main",
            ":" + name + "_assets",
            ":" + name + "_dev_config",
            ":" + name + "_generated_main",
            ":" + name + "_code_asset",
        ],
    )
