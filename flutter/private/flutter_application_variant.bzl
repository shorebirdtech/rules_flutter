"""`flutter_application_variant`: an application built from another's program with a different `main`."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:structs.bzl", "structs")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "link_hook_runner_attr")
load("//flutter:providers.bzl", "FlutterApplicationInputsInfo")
load("//flutter/private:code_asset_libraries.bzl", "code_asset_libraries_aspect")
load("//flutter/private:common.bzl", "FLUTTER_APPLICATION_TOOL_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "flutter_deps_attr")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_application.bzl", "flutter_application_build")

def _check_required_packages(label, deps, required):
    """Fails unless the program's dependencies bring each of `required`.

    Stated for what the program needs and the compile would otherwise report as
    an unresolved import in a file the user did not write.
    """
    if not required:
        return
    have = {}
    for dep in deps:
        if DartInfo in dep:
            for package in dep[DartInfo].transitive_packages.to_list():
                have[package.package_name] = True
    for name in required:
        if name not in have:
            fail((
                "%s: the program needs `package:%s`, which no dependency of it brings; " +
                "add `@<hub>//:%s` (your pub hub's target for it) to `deps`."
            ) % (label, name, name))

def _flutter_application_variant_impl(ctx):
    program = ctx.attr.application[FlutterApplicationInputsInfo].inputs
    deps = program.deps + ctx.attr.deps
    _check_required_packages(ctx.label, deps, ctx.attr.requires_packages)

    # Everything not named here is the application's own: its package and so
    # its `package:` URIs and asset keys, its assets, native dependencies and
    # build options. `label` in particular stays the application's, which is
    # what makes `package:<app>/…` imports in the new `main` resolve.
    #
    # The application's own `main` stays a source: the new one is likely to
    # import it (`package:<app>/main.dart`) to start the app it tests.
    kept_main = [program.main] if program.main not in program.srcs else []
    inputs = structs.to_dict(program) | {
        "main": ctx.file.main,
        "srcs": program.srcs + kept_main + ctx.files.srcs + ctx.files.unchecked_srcs,
        "unchecked_srcs": program.unchecked_srcs + ctx.files.unchecked_srcs,
        "deps": deps,
        "defines": program.defines + ctx.attr.defines,
        "code_assets": program.code_assets,
    }
    return flutter_application_build(ctx, struct(**inputs))

flutter_application_variant = rule(
    implementation = _flutter_application_variant_impl,
    attrs = FLUTTER_APPLICATION_TOOL_ATTRS | PLATFORM_CONSTRAINT_ATTRS | link_hook_runner_attr() | apple_support.platform_constraint_attrs() | {
        "application": attr.label(
            doc = "The `flutter_application` whose program this is a variant of.",
            mandatory = True,
            providers = [FlutterApplicationInputsInfo],
        ),
        "main": attr.label(
            doc = "The entry point, in place of the application's `main`. It may be anywhere: a file outside the application's `lib/` is compiled under the app scheme (`org-dartlang-app:///<workspace path>`), as an application's own `main` outside `lib/` is.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Dart sources added to the application's.",
            allow_files = [".dart"],
        ),
        "unchecked_srcs": attr.label_list(
            doc = "Dart sources added to the application's like `srcs`, whose imports are not checked against the program's `deps`: files a rule wrote for the program (an integration test's bootstrap and support library), whose imports are that rule's to get right and need not be `deps` of the user's target. `main` is exempt when listed here too.",
            allow_files = [".dart"],
        ),
        # Dependencies added to the application's: a plugin only these bring is
        # registered in the variant and not in the application.
        "deps": flutter_deps_attr(aspects = [code_asset_libraries_aspect]),
        "defines": attr.string_list(
            doc = "Dart environment defines (`-D`) added after the application's.",
        ),
        "requires_packages": attr.string_list(
            doc = "Dart packages the program must have, by name: analysis fails, naming the package and the hub target to add, if no dependency of the application or of `deps` brings one. For a program whose added sources import packages the application does not need, as an integration test's.",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = """The `flutter_application` `application`, rebuilt with another `main`.

Compiles the application's program again with `main` as its entry point, `srcs`,
`deps` and `defines` added to the application's (its own `main` stays among its
sources, for the new one to import), and everything else the
application's own: its Dart package (so `package:<name>/…` imports in the new
`main` resolve against the application's `lib/`), assets, native dependencies,
code assets, shaders and build options. It returns what `flutter_application`
returns (`FlutterApplicationInfo`, `DefaultInfo`, the output groups and, in a
debug build, the dev config), so each platform's app rule takes it as its
`application` unchanged.

Two uses are the same shape: an entry point that is not the application's
(`flutter run -t test_driver/app.dart`), and a test program that runs the
application under a harness. Neither needs the application's own `main` to
change, and neither rebuilds what the program does not touch: the Flutter
framework's and each package's kernels are shared with the application.

```starlark
flutter_application(
    name = "app_flutter",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = ["@deps//:flutter"],
)

flutter_application_variant(
    name = "driver_flutter",
    application = ":app_flutter",
    main = "test_driver/app.dart",
    srcs = ["test_driver/banner.dart"],
)

flutter_macos_app(
    name = "driver_app",
    application = ":driver_flutter",
    bundle_id = "com.example.myapp.driver",
)
```
""",
)
