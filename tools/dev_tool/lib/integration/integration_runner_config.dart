/// What an integration test rule tells the host runner about the run: the JSON
/// file `FLUTTER_INTEGRATION_TEST_CONFIG` names.
///
/// The rule writes it and the runner reads it, in two languages, so a key
/// that is missing or of the wrong kind is named in the error, with the file
/// it came from: a runner that guessed would launch the wrong app, or none.
library;

import 'dart:convert';

/// The kind of device an integration test runs on. One test rule per family,
/// as one runner per family.
enum IntegrationFamily {
  /// Headless Chrome on the host.
  web('web'),

  /// The host's own desktop: macOS or Windows, or on Linux an X server of the
  /// test's own.
  desktop('desktop'),

  /// A simulator the runner creates.
  iosSimulator('ios_simulator'),

  /// An attached phone or an emulator.
  android('android');

  const IntegrationFamily(this.key);

  /// The name the rule writes.
  final String key;
}

/// What a test needs to have its goldens compared on the host.
class GoldenServiceConfig {
  /// A golden service, started as [executable] with [environment], comparing
  /// for the test whose source has the `short_path` [testSource].
  const GoldenServiceConfig({
    required this.executable,
    required this.environment,
    required this.testSource,
  });

  /// The runfiles path of the golden service's executable: a `flutter_test`.
  final String executable;

  /// What the service is started with, which its `flutter_test` rule says: where
  /// its kernel, `flutter_tester` and assets are in the runfiles.
  final Map<String, String> environment;

  /// The `short_path` of the integration test's source: goldens are relative to
  /// its directory.
  final String testSource;
}

/// The settings of one run.
class IntegrationRunnerConfig {
  /// Settings read from [parse].
  const IntegrationRunnerConfig({
    required this.family,
    required this.appArtifacts,
    required this.launcher,
    required this.testDisplayName,
    required this.env,
    this.goldens,
  });

  /// Reads the JSON text [source], read from [origin] (a path, for the
  /// message). Throws a [FormatException] naming the key that is wrong.
  factory IntegrationRunnerConfig.parse(String source, {String? origin}) {
    final where = origin == null ? 'the config' : 'the config $origin';
    final Object? decoded;
    try {
      decoded = json.decode(source);
    } on FormatException catch (e) {
      throw FormatException('$where is not JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('$where is not a JSON object');
    }
    final Map<String, Object?> config = decoded;

    String string(String key) {
      final value = config[key];
      if (value is! String || value.isEmpty) {
        throw FormatException(
          '$where: "$key" must be a non-empty string, got '
          '${value == null ? 'nothing' : json.encode(value)}',
        );
      }
      return value;
    }

    final familyName = string('family');
    final family = IntegrationFamily.values
        .where((f) => f.key == familyName)
        .firstOrNull;
    if (family == null) {
      throw FormatException(
        '$where: "family" is "$familyName", which is none of '
        '${IntegrationFamily.values.map((f) => '"${f.key}"').join(', ')}',
      );
    }

    final artifacts = config['appArtifacts'];
    if (artifacts is! List ||
        artifacts.isEmpty ||
        artifacts.any((a) => a is! String)) {
      throw FormatException(
        '$where: "appArtifacts" must be a non-empty list of the app\'s '
        'runfiles paths, got ${json.encode(artifacts)}',
      );
    }

    final launcher = config['launcher'];
    if (launcher is! Map<String, Object?>) {
      throw FormatException(
        '$where: "launcher" must be an object, got ${json.encode(launcher)}',
      );
    }

    final env = config['env'];
    if (env is! Map || env.values.any((v) => v is! String)) {
      throw FormatException(
        '$where: "env" must be an object of strings, got ${json.encode(env)}',
      );
    }

    GoldenServiceConfig? goldens;
    final goldenConfig = config['goldens'];
    if (goldenConfig != null) {
      if (goldenConfig is! Map<String, Object?>) {
        throw FormatException(
          '$where: "goldens" must be an object, got ${json.encode(goldenConfig)}',
        );
      }
      String goldenString(String key) {
        final value = goldenConfig[key];
        if (value is! String || value.isEmpty) {
          throw FormatException(
            '$where: "goldens.$key" must be a non-empty string, got '
            '${value == null ? 'nothing' : json.encode(value)}',
          );
        }
        return value;
      }

      final goldenEnv = goldenConfig['environment'];
      if (goldenEnv is! Map || goldenEnv.values.any((v) => v is! String)) {
        throw FormatException(
          '$where: "goldens.environment" must be an object of strings, got '
          '${json.encode(goldenEnv)}',
        );
      }
      goldens = GoldenServiceConfig(
        executable: goldenString('executable'),
        environment: goldenEnv.cast<String, String>(),
        testSource: goldenString('testSource'),
      );
    }

    return IntegrationRunnerConfig(
      family: family,
      appArtifacts: artifacts.cast<String>(),
      launcher: launcher,
      testDisplayName: string('testDisplayName'),
      env: env.cast<String, String>(),
      goldens: goldens,
    );
  }

  /// The kind of device the test runs on.
  final IntegrationFamily family;

  /// The runfiles paths of the app's files, from which the device picks the one
  /// it launches.
  final List<String> appArtifacts;

  /// The runner's own settings: which Chrome, which simulator, and so on. What
  /// is in it belongs to the family.
  final Map<String, Object?> launcher;

  /// What the test calls itself, for the report: its label.
  final String testDisplayName;

  /// What the test was given in `env`, which the runner's own environment
  /// already carries.
  final Map<String, String> env;

  /// How the goldens of the test are compared, or null when it has no golden
  /// comparator: a golden it asks for then fails, saying so.
  final GoldenServiceConfig? goldens;

  /// The runfiles path of the browser a web test runs in: the launcher's
  /// `chrome`. A [FormatException] names the key when the runner did not give
  /// one, since a browser guessed at would not be the pinned one.
  String get chromePath => _launcherPath('chrome', 'the browser\'s');

  /// The runfiles path of the `adb` an Android test drives its device with: the
  /// launcher's `adb`. A [FormatException] names the key when the runner did
  /// not give one, since an `adb` found on the host would not be the one of the
  /// SDK the app was built against.
  String get adbPath => _launcherPath('adb', 'the SDK\'s');

  /// The device type of the simulator an iOS test runs on, as `simctl list
  /// devicetypes` names it (`iPhone 16`): the launcher's `deviceType`. A
  /// [FormatException] names the key when the runner did not give one.
  String get simulatorDeviceType => _launcherString(
    'deviceType',
    'the simulator\'s device type',
    required: true,
  );

  /// The runtime of that simulator: the launcher's `runtime`, which is empty
  /// for the newest installed. A [FormatException] names the key when it is
  /// not a string at all.
  String get simulatorRuntime =>
      _launcherString('runtime', 'the simulator\'s runtime', required: false);

  /// The Linux runtime the runner carries (`flutter_linux_runtime`'s runfiles
  /// paths), or null when it carries none, as off Linux. A [FormatException]
  /// names the key when it is not an object.
  Map<String, Object?>? get linuxRuntime {
    final value = launcher['linuxRuntime'];
    if (value == null) return null;
    if (value is! Map<String, Object?>) {
      throw FormatException(
        'the config: "launcher.linuxRuntime" must be an object, got '
        '${json.encode(value)}',
      );
    }
    return value;
  }

  String _launcherString(String key, String what, {required bool required}) {
    final value = launcher[key];
    if (value is! String || (required && value.isEmpty)) {
      throw FormatException(
        'the config: "launcher.$key" must be a '
        '${required ? 'non-empty ' : ''}string, $what, got '
        '${value == null ? 'nothing' : json.encode(value)}',
      );
    }
    return value;
  }

  String _launcherPath(String key, String whose) {
    final value = launcher[key];
    if (value is! String || value.isEmpty) {
      throw FormatException(
        'the config: "launcher.$key" must be a non-empty string, $whose '
        'runfiles path, got '
        '${value == null ? 'nothing' : json.encode(value)}',
      );
    }
    return value;
  }
}
