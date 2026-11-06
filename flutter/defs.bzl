"""Core rules for building Flutter applications.

This is the main entry point for rules_flutter. It exports platform-agnostic
rules that compile Dart code, bundle assets, and run tests.

## Recommended (start here)

- `flutter_application`: Compiles Dart code (kernel + AOT) and bundles assets.
    This is the primary rule — it produces a `FlutterApplicationInfo` provider
    that platform-specific packaging rules consume.
- Flavors: `flavor` on `flutter_application` (and `flutter_web_app`) makes the
    target that flavor, as `flutter build --flavor` does: `appFlavor` is set and
    the pub assets and shaders whose `flavors:` name it are bundled. Declare one
    application per flavor; see the README's Flavors section.
- `flutter_library`: Collects Flutter Dart sources and assets into a reusable
    dependency. Wire into `flutter_application` via `deps`.
- `flutter_plugin`: Declares a Flutter plugin with optional Dart registration
    class and/or native shared library dependencies.
- `flutter_test`: Runs Flutter widget tests using the flutter_tester runtime.
- `flutter_application_variant` (`@rules_flutter//flutter:integration_test.bzl`): A
    `flutter_application` rebuilt with another `main`, for a test driver or an
    integration test's program.
- `@rules_flutter//flutter:integration_test.bzl` — `flutter_macos_integration_test`,
    `flutter_windows_integration_test`, `flutter_web_integration_test`,
    `flutter_android_integration_test`,
    `flutter_ios_simulator_integration_test` and the rules they compose: `package:integration_test` tests run in the real app on a
    device, or in a headless Chrome, and reported per test.
- `flutter_tester_binary`: Runs a program under flutter_tester as an executable, for build actions.
- `flutter_profile_build`: Builds targets in profile mode whatever the command line
    says, to check a profile build in a test.

## Advanced / Low-Level

Most users don't need these directly. `flutter_application` composes them
internally. They are exported for advanced use cases like custom pipelines.

- `flutter_kernel_target`: Runs the Flutter frontend compiler to produce a
    kernel .dill file from Dart sources.
- `flutter_aot_target`: Runs gen_snapshot to AOT-compile a kernel .dill into
    native code (ELF .so or Mach-O dylib).
- `flutter_asset_bundle`: Bundles Flutter assets (images, fonts, shaders)
    into a flutter_assets/ tree artifact.

## Platform packaging

After `flutter_application`, use platform-specific rules to produce runnable
artifacts:

- `@rules_flutter//flutter:macos.bzl` — `flutter_macos_app` + composable rules
- `@rules_flutter//flutter:ios.bzl` — `flutter_ios_app` + composable rules
- `@rules_flutter//flutter:linux.bzl` — `flutter_linux_app` + composable rules
- `@rules_flutter//flutter:windows.bzl` — `flutter_windows_app` + composable rules
- `@rules_flutter//flutter:web.bzl` — `flutter_web_app` + composable rules (takes source directly, not a flutter_application target)
"""

load("//flutter/private:flutter_aot_target.bzl", _flutter_aot_target = "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", _flutter_application = "flutter_application")
load("//flutter/private:flutter_asset_bundle.bzl", _flutter_asset_bundle = "flutter_asset_bundle")
load("//flutter/private:flutter_gen_l10n.bzl", _flutter_gen_l10n = "flutter_gen_l10n")
load("//flutter/private:flutter_kernel_target.bzl", _flutter_kernel_target = "flutter_kernel_target")
load("//flutter/private:flutter_library.bzl", _flutter_library = "flutter_library")
load("//flutter/private:flutter_native_library.bzl", _flutter_native_library = "flutter_native_library")
load("//flutter/private:flutter_plugin.bzl", _flutter_plugin = "flutter_plugin")
load("//flutter/private:flutter_profile_build.bzl", _flutter_profile_build = "flutter_profile_build")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test", _flutter_tester_binary = "flutter_tester_binary")
load("//flutter/private:test_config.bzl", "find_test_config")

flutter_aot_target = _flutter_aot_target

def flutter_application(name, package_name = "", **kwargs):
    """Compiles a Flutter application with stable package: URIs for hot reload.

    Auto-derives `package_name` from the rule name if not explicitly set.
    This ensures the kernel uses `package:<name>/main.dart` URIs instead of
    sandbox `file:///` URIs, which is required for hot reload incremental
    deltas to match the running application's library URIs.

    `flavor` makes the application one flavor (`appFlavor`, and the pub
    packages' `flavors:` assets and shaders): declare one application per
    flavor.

    Args:
        name: Target name.
        package_name: Dart package name (from pubspec.yaml). Defaults to name.
        **kwargs: All other arguments forwarded to the underlying rule.
    """
    _flutter_application(
        name = name,
        package_name = package_name or name,
        **kwargs
    )

flutter_asset_bundle = _flutter_asset_bundle
flutter_gen_l10n = _flutter_gen_l10n
flutter_kernel_target = _flutter_kernel_target
flutter_library = _flutter_library
flutter_native_library = _flutter_native_library
flutter_plugin = _flutter_plugin
flutter_profile_build = _flutter_profile_build

def flutter_test(name, main, test_config = None, **kwargs):
    """Compiles a Flutter test and runs it under flutter_tester.

    Like `flutter test`, runs the suite through the nearest
    `flutter_test_config.dart`: the first found walking up from `main`'s
    directory, ending after the directory holding `pubspec.yaml`. The search
    sees only this BUILD file's package; name a config above it with
    `test_config`. See the rule's own docs for every other attribute.

    Args:
        name: Target name.
        main: The test's entry point.
        test_config: The suite's `flutter_test_config.dart`, in place of the
            one the search would find.
        **kwargs: Forwarded to the rule.
    """
    if test_config == None and type(main) in ("string", "Label"):
        # `main` as a path in this package, however it is spelled: the search
        # sees nothing outside the package.
        label = native.package_relative_label(main)
        here = native.package_relative_label(":" + name)
        if (label.repo_name, label.package) == (here.repo_name, here.package):
            # `allow_empty`: the lookup asks whether each candidate config
            # exists, and most tests have none.
            test_config = find_test_config(
                label.name,
                lambda path: bool(native.glob([path], allow_empty = True)),
            )
    _flutter_test(name = name, main = main, test_config = test_config, **kwargs)

flutter_tester_binary = _flutter_tester_binary
