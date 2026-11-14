/// Checks that a web app's own version.json gives the version its program
/// reports.
///
/// A web bundle carries a version.json, which the web `package_info_plus`
/// (and the plugins like it) reads for the app's `version` and `build_number`.
/// The bundle writes one from its `flutter_application`'s `build_name` and
/// `build_number` unless the app brings its own (`version_json`, or a
/// `web/version.json` that `flutter_web_app` finds). The program reports the
/// application's version as `appBuildName` and `appBuildNumber` either way,
/// the defaults `1.0.0` and `1` when the application sets none. So the file's
/// `version` and `build_number` must be that version, as strings, or the app
/// would report two versions. The file is known only when it is built, so this
/// is checked here. `--version-setting` and `--build-number-setting` name the
/// build setting that gave a value, such as
/// `--@rules_flutter//flutter:build_number`, which the file cannot follow.
///
/// On success the tool writes `--stamp`, which the build requires so that a
/// file that fails the check fails the build.
///
/// It has no package dependencies, and runs with the bare Dart SDK.
///
/// Usage:
///   dart check_web_version_json.dart --version-json <file> --name <shown name>
///       --bundle <label> --application <label>
///       --version <value> --version-default <true|false>
///       --build-number <value> --build-number-default <true|false>
///       [--version-setting <flag>] [--build-number-setting <flag>]
///       --stamp <file>
import 'dart:convert';
import 'dart:io';

/// A field of version.json: the application's attribute that gives it, and
/// the getter the program reads the same value with.
class VersionField {
  final String field;
  final String argument;
  final String reportedAs;

  const VersionField(this.field, this.argument, this.reportedAs);
}

const versionFields = [
  VersionField('version', 'build_name', 'appBuildName'),
  VersionField('build_number', 'build_number', 'appBuildNumber'),
];

/// What the application reports for one field: its [value], whether that is
/// the default because the application sets none, and the build [setting]
/// that gave it, if one did.
class Reported {
  final String value;
  final bool isDefault;
  final String? setting;

  const Reported(this.value, {required this.isDefault, this.setting});
}

/// The problems with the version.json [text], one message each; empty when
/// it gives the version its program reports. [name] is the file as the user
/// knows it, [bundle] the web app's label, [application] its application's,
/// and [expected] what the application reports, by version.json field.
List<String> versionJsonProblems({
  required String text,
  required String name,
  required String bundle,
  required String application,
  required Map<String, Reported> expected,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return [
      'ERROR: $name, the version.json of $bundle, is not JSON: ${e.message}',
    ];
  }
  if (decoded is! Map<String, Object?>) {
    return [
      'ERROR: $name, the version.json of $bundle, is not a JSON object: '
          'its fields are `app_name`, `version`, `build_number` and '
          '`package_name`.',
    ];
  }
  final problems = <String>[];
  for (final f in versionFields) {
    final want = expected[f.field]!;
    final String gives;
    if (!decoded.containsKey(f.field)) {
      gives = 'gives no `${f.field}`, so the app reports an empty one';
    } else {
      final value = decoded[f.field];
      if (value == want.value) continue;
      gives = value is String
          ? 'gives `${f.field}` "$value"'
          : 'gives `${f.field}` as ${jsonEncode(value)}, which is not a string';
    }
    final setting = want.setting;
    problems.add(
      setting != null
          ? 'ERROR: The bundle of $bundle would not report the version its '
                'program does: $name $gives, and `$setting` gives the '
                'application $application "${want.value}" for this build (its '
                '`${f.argument}`, as `${f.reportedAs}`).\n'
                '  Delete $name, which states its own version and cannot '
                'follow the setting: the bundle then writes version.json from '
                'the application.'
          : 'ERROR: The bundle of $bundle would not report the version its program '
                'does: $name $gives, and the application $application reports '
                '"${want.value}" (its `${f.argument}`${want.isDefault ? ', unset and so the default' : ''}, '
                'as `${f.reportedAs}`).\n'
                '  Give $name `"${f.field}": "${want.value}"`, or set the version on '
                'the application alone and delete $name: the bundle then writes '
                'version.json from the application.',
    );
  }
  return problems;
}

/// Checks [args] (the command line) and returns the exit code.
int run(List<String> args) {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (!args[i].startsWith('--') || i + 1 >= args.length) {
      stderr.writeln('ERROR: unexpected argument ${args[i]}.');
      return 2;
    }
    options[args[i].substring(2)] = args[i + 1];
  }
  for (final required in [
    'version-json',
    'name',
    'bundle',
    'application',
    'version',
    'version-default',
    'build-number',
    'build-number-default',
    'stamp',
  ]) {
    if (!options.containsKey(required)) {
      stderr.writeln('ERROR: missing --$required.');
      return 2;
    }
  }
  final problems = versionJsonProblems(
    text: File(options['version-json']!).readAsStringSync(),
    name: options['name']!,
    bundle: options['bundle']!,
    application: options['application']!,
    expected: {
      'version': Reported(
        options['version']!,
        isDefault: options['version-default'] == 'true',
        setting: options['version-setting'],
      ),
      'build_number': Reported(
        options['build-number']!,
        isDefault: options['build-number-default'] == 'true',
        setting: options['build-number-setting'],
      ),
    },
  );
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    return 1;
  }
  File(options['stamp']!).writeAsStringSync('');
  return 0;
}

void main(List<String> args) => exit(run(args));
