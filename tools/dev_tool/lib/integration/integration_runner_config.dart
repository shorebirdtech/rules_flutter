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

  /// The host's own desktop: macOS, Linux or Windows.
  desktop('desktop'),

  /// A simulator the runner creates.
  iosSimulator('ios_simulator'),

  /// An attached phone or an emulator.
  android('android');

  const IntegrationFamily(this.key);

  /// The name the rule writes.
  final String key;
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

    return IntegrationRunnerConfig(
      family: family,
      appArtifacts: artifacts.cast<String>(),
      launcher: launcher,
      testDisplayName: string('testDisplayName'),
      env: env.cast<String, String>(),
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

  /// The runfiles path of the browser a web test runs in: the launcher's
  /// `chrome`. A [FormatException] names the key when the runner did not give
  /// one, since a browser guessed at would not be the pinned one.
  String get chromePath {
    final value = launcher['chrome'];
    if (value is! String || value.isEmpty) {
      throw FormatException(
        'the config: "launcher.chrome" must be a non-empty string, the '
        'browser\'s runfiles path, got '
        '${value == null ? 'nothing' : json.encode(value)}',
      );
    }
    return value;
  }
}
