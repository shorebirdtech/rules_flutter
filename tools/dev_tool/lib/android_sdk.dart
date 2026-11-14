/// The `adb` and `aapt2` an Android run drives its device with.
///
/// They are the workspace's own: the `@androidsdk` of the module graph, built
/// by Bazel, so the device is driven by the SDK the app is built with. That is
/// the SDK the root module chose: rules_android's `android_sdk_repository`,
/// which reads `ANDROID_HOME`, or hermetic_android_toolchains' download, which
/// needs nothing installed. Upstream `flutter` likewise runs the `adb` of the
/// Android SDK it builds with rather than one on `PATH`.
///
/// A workspace with no Android SDK has an `@androidsdk` all the same, because
/// rules_android declares one for every module that depends on it: with no
/// `ANDROID_HOME`, `android_sdk_repository` writes a placeholder with neither
/// tool. [WorkspaceAndroidSdk] tells the two apart with a `bazel query`, which
/// analyses nothing, so a workspace without Android pays one query and builds
/// nothing Android.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import 'dev_tool_exception.dart';
import 'toolchain_info.dart' show BazelRunner;

/// The SDK tools the dev tool runs, as absolute paths.
class AndroidSdkTools {
  /// The `adb` for this host: installs, starts, forwards and reads logcat.
  final String adb;

  /// The `aapt2` that reads an APK's package and launchable activity.
  final String aapt2;

  const AndroidSdkTools({required this.adb, required this.aapt2});
}

/// The package of rules_flutter that names `@androidsdk`'s tools, which the
/// workspace itself may not see: a root module needs no `use_repo` of
/// `androidsdk` to build an Android app.
const androidSdkPackage = '@rules_flutter//tools/dev_tool/android_sdk';

/// The `adb` and `aapt2` labels, as `androidSdkPackage` names them.
const androidSdkToolLabels = [
  '$androidSdkPackage:adb',
  '$androidSdkPackage:aapt2',
];

/// Whether `@androidsdk` has the tools: its `sdk` target's siblings named
/// `adb` or `aapt2`. `labels(actual, …)` follows the alias to the package of
/// the SDK hub without loading any platform's SDK, so nothing is downloaded.
const androidSdkPresenceQuery =
    'attr(name, "^(adb|aapt2)\$", '
    'siblings(labels(actual, $androidSdkPackage:sdk)))';

/// Where an Android run gets its SDK tools.
abstract class AndroidSdk {
  const AndroidSdk();

  /// The tools, or null when there is no Android SDK to take them from.
  Future<AndroidSdkTools?> find();

  /// Why [find] answered null, completing "cannot run on an Android device:".
  String get absence;

  /// The tools. Throws a [DevToolException] saying what to set up when there
  /// is no Android SDK.
  Future<AndroidSdkTools> require() async {
    final tools = await find();
    if (tools != null) return tools;
    throw DevToolException(
      'Cannot run on an Android device: $absence',
    );
  }
}

/// The workspace's Android SDK, asked once per run and only when a run needs
/// an Android device.
class WorkspaceAndroidSdk extends AndroidSdk {
  final String workspace;
  final BazelRunner _runBazel;

  /// The user's `--config` flags, which can be what makes the workspace load
  /// at all. The query and `bazel info` take these alone: a `--build-arg` can
  /// be an option only `bazel build` knows, which `bazel query` refuses.
  final List<String> configFlags;

  /// The options the run builds its app with, but for the device's own (an
  /// Android device's ABI, which it takes `adb` to ask).
  ///
  /// The tools are built and found in exactly these: Bazel keeps one set of
  /// options' analysis, and a command in any other throws it away, so the
  /// app's next build would analyse its whole graph again. The tools reach the
  /// host platform through their own targets' transition, whatever these say.
  final List<String> buildFlags;

  Future<AndroidSdkTools?>? _tools;

  WorkspaceAndroidSdk({
    required this.workspace,
    required BazelRunner runBazel,
    this.configFlags = const [],
    this.buildFlags = const [],
  }) : _runBazel = runBazel;

  /// Built the first time it is asked; a failed query or build throws a
  /// [DevToolException] naming the command, and is asked again next time.
  @override
  Future<AndroidSdkTools?> find() async {
    final pending = _tools ??= _resolve();
    try {
      return await pending;
    } catch (_) {
      if (identical(_tools, pending)) _tools = null;
      rethrow;
    }
  }

  @override
  String get absence =>
      'this workspace has no Android SDK: `bazel query '
      '\'$androidSdkPresenceQuery\'` in $workspace finds no `adb` or `aapt2` '
      'in `@androidsdk`.\n'
      'Take the SDK from hermetic_android_toolchains, which downloads it, or '
      'point ANDROID_HOME at an installed one for rules_android\'s '
      '`android_sdk_repository`.';

  Future<AndroidSdkTools?> _resolve() async {
    final presence = await _bazel([
      'query',
      androidSdkPresenceQuery,
      ...configFlags,
    ], what: 'ask whether the workspace has an Android SDK');
    final present = LineSplitter.split(
      presence,
    ).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (present.isEmpty) return null;
    if (present.length != 2) {
      throw DevToolException(
        '`@androidsdk` has ${present.join(' and ')} but not both of `adb` and '
        '`aapt2`, which an Android run needs.',
      );
    }

    await _bazel([
      'build',
      ...buildFlags,
      ...androidSdkToolLabels,
    ], what: 'build the Android SDK\'s adb and aapt2');
    final paths = await _bazel([
      'cquery',
      'set(${androidSdkToolLabels.join(' ')})',
      ...buildFlags,
      '--output=starlark',
      '--starlark:expr=str(target.label) + " " + '
          'providers(target)["FilesToRunProvider"].executable.path',
    ], what: 'find the Android SDK\'s adb and aapt2');
    final executionRoot = await _bazel([
      'info',
      'execution_root',
      ...configFlags,
    ], what: 'find the execution root');
    return androidSdkToolsFrom(
      cquery: paths,
      executionRoot: executionRoot.trim(),
    );
  }

  Future<String> _bazel(List<String> args, {required String what}) async {
    final result = await _runBazel(args, workingDirectory: workspace);
    if (result.exitCode != 0) {
      final stderr = (result.stderr as String).trimRight();
      final tail = stderr.split('\n');
      throw DevToolException(
        'Could not $what.\n'
        '  cd $workspace && bazel ${args.join(' ')}\n'
        '  exit ${result.exitCode}\n'
        '${tail.length > 40 ? tail.sublist(tail.length - 40).join('\n') : stderr}',
      );
    }
    return result.stdout as String;
  }
}

/// [AndroidSdkTools] from the cquery's `<label> <execroot-relative path>`
/// lines and the [executionRoot] `bazel info execution_root` answers.
///
/// The paths are the `host_tool` targets' own links, built files under the
/// execution root, each with the runfiles a runner script such as the
/// hermetic SDK's `aapt2` reads.
AndroidSdkTools androidSdkToolsFrom({
  required String cquery,
  required String executionRoot,
}) {
  if (!p.isAbsolute(executionRoot)) {
    throw DevToolException(
      '`bazel info execution_root` answered something that is not a path: '
      '$executionRoot',
    );
  }
  String? adb;
  String? aapt2;
  for (final line in LineSplitter.split(cquery)) {
    final trimmed = line.trim();
    final space = trimmed.lastIndexOf(' ');
    if (space < 0) continue;
    final label = trimmed.substring(0, space);
    final absolute = p.join(executionRoot, trimmed.substring(space + 1));
    switch (label.substring(label.lastIndexOf(':') + 1)) {
      case 'adb':
        adb = absolute;
      case 'aapt2':
        aapt2 = absolute;
    }
  }
  if (adb == null || aapt2 == null) {
    throw DevToolException(
      'The cquery of $androidSdkToolLabels named '
      '${adb == null ? 'no adb' : 'no aapt2'}:\n$cquery',
    );
  }
  return AndroidSdkTools(adb: adb, aapt2: aapt2);
}
