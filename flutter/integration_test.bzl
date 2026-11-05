"""Integration tests: `package:integration_test` suites run in an app on a device, reported per test.

An integration test is run as the application with its test as the program
(`flutter_application_variant`, whose `main` is the generated
`flutter_integration_bootstrap`), and the host drives the suite it runs over the
app's VM service, as `flutter test integration_test/x_test.dart -d <device>`
does, or, for a web app, which has none, over the browser's DevTools protocol. Each `testWidgets` is a test case: `--test_filter`, `shard_count` and the
JUnit report see each one.

Tier 1, the convenience macros: one per platform, each composing the bootstrap,
the variant, the platform's app rule and the test.

- `flutter_macos_integration_test`
- `flutter_windows_integration_test`
- `flutter_web_integration_test`
- `flutter_android_integration_test`
- `flutter_ios_simulator_integration_test`

Tier 2, the composable rules:

- `flutter_integration_bootstrap`: the program an integration test file runs as.
- `flutter_application_variant`: a `flutter_application` rebuilt with another
  `main`, plus extra `srcs`, `deps` and `defines`.
- `flutter_desktop_integration_test`: runs a desktop app on the host's desktop.
- `flutter_desktop_runner`: where it runs.
- `flutter_web_bundle_integration_test`: runs a web bundle in a headless Chrome.
- `flutter_chrome_runner`: a headless Chrome of its own, where a web test runs.
- `flutter_android_app_integration_test`: runs an Android app on an attached device.
- `flutter_android_device_runner`: which `adb` drives that device.
- `flutter_ios_app_integration_test`: runs an iOS app on a simulator of its own.
- `flutter_ios_simulator_runner`: which simulator that is.
"""

load("//flutter:android.bzl", "flutter_android_app")
load("//flutter:ios.bzl", "flutter_ios_app")
load("//flutter:macos.bzl", "flutter_macos_app")
load("//flutter:web.bzl", "flutter_web_app")
load("//flutter:windows.bzl", "flutter_windows_app")
load("//flutter/private:flutter_application_variant.bzl", _flutter_application_variant = "flutter_application_variant")
load("//flutter/private:flutter_integration_bootstrap.bzl", _flutter_integration_bootstrap = "flutter_integration_bootstrap")
load("//flutter/private:flutter_integration_test.bzl", _flutter_android_app_integration_test = "flutter_android_app_integration_test", _flutter_android_device_runner = "flutter_android_device_runner", _flutter_chrome_runner = "flutter_chrome_runner", _flutter_desktop_integration_test = "flutter_desktop_integration_test", _flutter_desktop_runner = "flutter_desktop_runner", _flutter_ios_app_integration_test = "flutter_ios_app_integration_test", _flutter_ios_simulator_runner = "flutter_ios_simulator_runner", _flutter_web_bundle_integration_test = "flutter_web_bundle_integration_test")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test")
load("//flutter/private:test_config.bzl", "find_test_config")

flutter_application_variant = _flutter_application_variant
flutter_integration_bootstrap = _flutter_integration_bootstrap
flutter_desktop_integration_test = _flutter_desktop_integration_test
flutter_desktop_runner = _flutter_desktop_runner
flutter_chrome_runner = _flutter_chrome_runner
flutter_web_bundle_integration_test = _flutter_web_bundle_integration_test
flutter_android_app_integration_test = _flutter_android_app_integration_test
flutter_android_device_runner = _flutter_android_device_runner
flutter_ios_app_integration_test = _flutter_ios_app_integration_test
flutter_ios_simulator_runner = _flutter_ios_simulator_runner

# What an integration test's program imports beyond the application.
_REQUIRED_PACKAGES = ["integration_test", "flutter_test"]

def _find_test_config(name, src):
    """The `flutter_test_config.dart` `flutter test` would find for `src`, or None.

    The same search `flutter_test` runs, over this package: a `src` in another
    package has none found, and names its own with `test_config`.
    """
    if type(src) not in ("string", "Label"):
        return None
    label = native.package_relative_label(src)
    here = native.package_relative_label(":" + name)
    if (label.repo_name, label.package) != (here.repo_name, here.package):
        return None
    return find_test_config(
        label.name,
        # `allow_empty`: the lookup asks whether each candidate config exists,
        # and most tests have none.
        lambda path: bool(native.glob([path], allow_empty = True)),
    )

def _golden_service(name, deps):
    """Declares the `flutter_test` that compares the test's goldens on the host.

    The host runner has no `dart:ui`, which comparing two pictures needs, so a
    `flutter_test` of the rule's own (`flutter/private/goldens/service.dart`)
    does it, as `flutter test` runs a `flutter_tester` to compare for the tool.
    It needs `package:flutter_test` and nothing else, and takes that of `deps`:
    the one that is `flutter_test`.

    Returns:
        The label of the service. It is the macro's own, named `__<name>_goldens`.
    """
    service = "__%s_goldens" % name
    _flutter_test(
        name = service,
        main = str(Label("//flutter/private/goldens:service.dart")),
        srcs = [str(Label("//flutter/private/goldens:comparator.dart"))],
        package_name = "rules_flutter_golden_service",
        deps = [d for d in deps if native.package_relative_label(d).name == "flutter_test"],
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
    )
    return ":" + service

def _program(name, src, application, deps, srcs, test_config):
    """Declares the bootstrap and the variant that is the test's program.

    Returns the label of the program: the application with the bootstrap as its
    `main` and `src` among its sources. Both are the macro's own, named
    `__<name>_…`, so the user never names them.
    """
    bootstrap = "__%s_bootstrap" % name
    program = "__%s_program" % name
    private = {
        "tags": ["manual"],
        "testonly": True,
        "visibility": ["//visibility:private"],
    }
    _flutter_integration_bootstrap(
        name = bootstrap,
        src = src,
        test_config = test_config,
        **private
    )
    _flutter_application_variant(
        name = program,
        application = application,
        main = ":%s.dart" % bootstrap,
        # The test, what it imports, and its config.
        srcs = [src] + srcs + ([test_config] if test_config else []),
        # The bootstrap and the support library staged beside it are the rule's
        # own files: what they import is not the user's `deps` to list.
        unchecked_srcs = [":" + bootstrap],
        deps = deps,
        requires_packages = _REQUIRED_PACKAGES,
        **private
    )
    return ":" + program

def flutter_macos_integration_test(
        name,
        src,
        application,
        bundle_id,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        size = "medium",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        **macos_app_kwargs):
    """Runs a `package:integration_test` file on macOS: the application with the test as its program.

    The app is built in debug mode and launched on the host's own desktop, which
    needs an unlocked, awake session; the test fails, saying so, when it is not
    one. One target per test file, as upstream launches the app once per file.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        bundle_id: The bundle identifier of the app, which is the application's own.
        deps: What the test imports beyond the application's own `deps`. It must
            bring `integration_test` and `flutter_test` (`@<hub>//:integration_test`
            and `@<hub>//:flutter_test`), which analysis fails without, naming them.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Environment variables for the runner and the app.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        size: The test size. `medium`: a window is launched and drawn.
        runner: A `flutter_desktop_runner`, to run the test with something other than
            the host's own desktop.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        **macos_app_kwargs: Passed to `flutter_macos_app`: `app_name`,
            `entitlements`, and the rest.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    flutter_macos_app(
        name = app,
        application = program,
        bundle_id = bundle_id,
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
        **macos_app_kwargs
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_desktop_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps),
        env = env,
        data = data,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = ["@platforms//os:macos"],
        **test_kwargs
    )

def flutter_windows_integration_test(
        name,
        src,
        application,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        size = "medium",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        **windows_app_kwargs):
    """Runs a `package:integration_test` file on Windows: the application with the test as its program.

    The app is built in debug mode and launched in the session the test runs in,
    which is where its window is created. Windows that overlap keep drawing, so
    tests need no turns on the screen. One target per test file, as upstream
    launches the app once per file.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        deps: What the test imports beyond the application's own `deps`. It must
            bring `integration_test` and `flutter_test` (`@<hub>//:integration_test`
            and `@<hub>//:flutter_test`), which analysis fails without, naming them.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Environment variables for the runner and the app.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        size: The test size. `medium`: a window is launched and drawn.
        runner: A `flutter_desktop_runner`, to run the test with something other than
            the host's own desktop.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        **windows_app_kwargs: Passed to `flutter_windows_app`: `app_name`, and the
            rest.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    flutter_windows_app(
        name = app,
        application = program,
        tags = ["manual"],
        testonly = True,
        visibility = ["//visibility:private"],
        # An app is for Windows, so is its test: another host skips both.
        target_compatible_with = ["@platforms//os:windows"],
        **windows_app_kwargs
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_desktop_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps),
        env = env,
        data = data,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = ["@platforms//os:windows"],
        **test_kwargs
    )

def flutter_web_integration_test(
        name,
        src,
        package_name,
        deps,
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        size = "medium",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        target_compatible_with = [],
        **web_app_kwargs):
    """Runs a `package:integration_test` file in headless Chrome: the web app with the test as its program.

    The app is built in debug mode and run in a pinned Chrome for Testing
    headless shell, which `flutter test` cannot do: it refuses web devices. The
    suite is driven over the browser's DevTools protocol, so each `testWidgets`
    is a case in Bazel's test report, which `flutter drive -d chrome` cannot
    give. One target per test file, as upstream launches the app once per file.

    The test's program is a web app of its own, built from the same sources as
    the application it tests and so compiled again for each test; the Flutter
    framework's and each package's kernels are shared.

    Intermediate targets `__<name>_bootstrap` and `__<name>_app` are this macro's:
    do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        package_name: The Dart package name of the app (`pubspec.yaml`'s `name:`),
            as `flutter_web_app` takes it.
        deps: The program's libraries: the app's own and what the test imports. It
            must bring `integration_test` and `flutter_test` (`@<hub>//:integration_test`
            and `@<hub>//:flutter_test`), which analysis fails without, naming them.
        srcs: The app's Dart sources and the files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Environment variables for the host runner.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        size: The test size. `medium`: a browser is launched and the app drawn.
        runner: A `flutter_chrome_runner`, to run the test in a browser other than
            the pinned one.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        target_compatible_with: The test's `target_compatible_with`. A host the pinned
            browser has no build for is incompatible whatever this says.
        **web_app_kwargs: Passed to `flutter_web_app`: `assets`, `web_dir`, `base_href`,
            and the rest. Not `main`, which is the test's program, nor `testonly`.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)

    bootstrap = "__%s_bootstrap" % name
    app = "__%s_app" % name
    private = {
        "tags": ["manual"],
        "testonly": True,
        "visibility": ["//visibility:private"],
    }
    _flutter_integration_bootstrap(
        name = bootstrap,
        src = src,
        test_config = test_config,
        # A web compile mounts no file-system root to name the test under.
        src_import = "relative",
        deps = deps,
        requires_packages = _REQUIRED_PACKAGES,
        **private
    )
    flutter_web_app(
        name = app,
        package_name = package_name,
        main = ":%s.dart" % bootstrap,
        # The test, what it imports, and its config.
        srcs = srcs + [src] + ([test_config] if test_config else []),
        # The bootstrap and the support library staged beside it are the rule's
        # own files: what they import is not the user's `deps` to list.
        unchecked_srcs = [":" + bootstrap],
        deps = deps,
        **(private | web_app_kwargs)
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_web_bundle_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps),
        env = env,
        data = data,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
        **test_kwargs
    )

def flutter_android_integration_test(
        name,
        src,
        application,
        package_name,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        size = "large",
        runner = None,
        abi = "arm64-v8a",
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        target_compatible_with = [],
        **android_app_kwargs):
    """Runs a `package:integration_test` file on an Android device: the application with the test as its program.

    The app is built in debug mode for `abi`, installed on the attached phone or
    running emulator (`ANDROID_SERIAL` names one when several are attached),
    started, and its suite driven through its VM service. A device is a
    precondition: with none attached, or several and none named, the test fails
    naming `adb devices`. The app stays installed afterwards. One target per
    test file, as upstream launches the app once per file.

    Android's `integration_test` library needs `androidx.test:runner`,
    `androidx.test:rules`, `androidx.test.espresso:espresso-core` and
    `com.google.guava:guava` in the workspace's `maven.install` of
    `rules_android_maven`; analysis names the ones that are missing.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program`, `__<name>_app`
    and, without a `runner`, `__<name>_runner` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        package_name: The application id of the app, as `flutter_android_app`
            takes it.
        deps: What the test imports beyond the application's own `deps`. It must
            bring `integration_test` and `flutter_test` (`@<hub>//:integration_test`
            and `@<hub>//:flutter_test`), which analysis fails without, naming them.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Refused when not empty: an app on a device cannot be handed an
            environment. Pass `defines` to the application instead.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        size: The test size. `large`: an APK is built, installed and started.
        runner: A `flutter_android_device_runner`. By default one that drives the
            device with the `adb` of `@androidsdk`, the Android SDK rules_android
            resolves from `ANDROID_HOME`.
        abi: The ABI the app is built for, which the device must run: `arm64-v8a`
            for a phone or an Apple-silicon emulator, `x86_64` for an Intel one.
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        target_compatible_with: The test's `target_compatible_with`.
        **android_app_kwargs: Passed to `flutter_android_app`: `permissions`,
            `namespace`, `manifest`, and the rest. Not `testonly`.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    private = {
        "tags": ["manual"],
        "visibility": ["//visibility:private"],
    }
    flutter_android_app(
        name = app,
        application = program,
        package_name = package_name,
        testonly = True,
        **(private | android_app_kwargs)
    )

    if runner == None:
        runner = ":__%s_runner" % name
        _flutter_android_device_runner(
            name = "__%s_runner" % name,
            # The SDK of the workspace the test is declared in: the
            # `@androidsdk` of the one SDK this workspace builds its APKs with.
            sdk = "@androidsdk//:sdk",
            **private
        )

    _flutter_android_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps),
        runner = runner,
        abi = abi,
        env = env,
        data = data,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

def flutter_ios_simulator_integration_test(
        name,
        src,
        application,
        bundle_id,
        deps = [],
        srcs = [],
        test_config = None,
        env = {},
        data = [],
        size = "large",
        runner = None,
        tags = [],
        timeout = None,
        shard_count = None,
        flaky = None,
        visibility = None,
        **ios_app_kwargs):
    """Runs a `package:integration_test` file on an iOS simulator: the application with the test as its program.

    The app is built in debug mode for the simulator, and the test makes a
    simulator of its own, boots it, installs and starts the app and drives its
    suite through its VM service, then shuts the simulator down and deletes it,
    however the test ends. A host with no iOS simulator runtime fails the test,
    saying `xcodebuild -downloadPlatform iOS`. One target per test file, as
    upstream launches the app once per file.

    Intermediate targets `__<name>_bootstrap`, `__<name>_program` and
    `__<name>_app` are this macro's: do not name them.

    Args:
        name: The test's name.
        src: The test file. Its `main` declares the tests, as for `flutter create`:
            `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and
            `testWidgets`, calling the app's own `main()`.
        application: The `flutter_application` the test runs. It may be in another
            package.
        bundle_id: The bundle identifier of the app, as `flutter_ios_app` takes it.
        deps: What the test imports beyond the application's own `deps`. It must
            bring `integration_test` and `flutter_test` (`@<hub>//:integration_test`
            and `@<hub>//:flutter_test`), which analysis fails without, naming them.
        srcs: Dart files `src` imports by relative path.
        test_config: The suite's `flutter_test_config.dart`. By default the one
            `flutter_test` would find for `src`, in this package.
        env: Refused when not empty: an app on a simulator cannot be handed an
            environment. Pass `defines` to the application instead.
        data: Files the test reads at run time, and its golden files:
            `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the
            directory of `src`, compared on the host. `bazel run :<name> --
            --update-goldens` writes them.
        size: The test size. `large`: an app is built, a simulator booted and the
            app installed.
        runner: A `flutter_ios_simulator_runner`, to run on another device type or
            runtime than the default (an iPhone 16 on the newest installed iOS).
        tags: Tags of the test.
        timeout: The test's `timeout`.
        shard_count: The test's `shard_count`: the tests of the file are divided
            among the shards, each on a simulator of its own.
        flaky: The test's `flaky`.
        visibility: The test's visibility.
        **ios_app_kwargs: Passed to `flutter_ios_app`: `app_name`, `entitlements`,
            and the rest. Not `testonly`.
    """
    if test_config == None:
        test_config = _find_test_config(name, src)
    program = _program(name, src, application, deps, srcs, test_config)

    app = "__%s_app" % name
    private = {
        "tags": ["manual"],
        "visibility": ["//visibility:private"],
    }
    flutter_ios_app(
        name = app,
        application = program,
        bundle_id = bundle_id,
        testonly = True,
        **(private | ios_app_kwargs)
    )

    test_kwargs = {}
    if runner != None:
        test_kwargs["runner"] = runner
    _flutter_ios_app_integration_test(
        name = name,
        app = ":" + app,
        src = src,
        golden_service = _golden_service(name, deps),
        # The simulator runs the architecture of the Mac it is on.
        sim_cpu = select({
            "@platforms//cpu:arm64": "sim_arm64",
            "//conditions:default": "x86_64",
        }),
        env = env,
        data = data,
        size = size,
        tags = tags,
        timeout = timeout,
        shard_count = shard_count,
        flaky = flaky,
        visibility = visibility,
        target_compatible_with = ["@platforms//os:macos"],
        **test_kwargs
    )
