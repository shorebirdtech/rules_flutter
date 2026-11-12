/// Checks that an app's bundle version is the version its program reports,
/// and that its Info.plist leaves the version keys to `build_name` and
/// `build_number`.
///
/// `flutter_ios_app` and `flutter_macos_app` always give rules_apple a version,
/// and rules_apple then replaces `CFBundleShortVersionString` and
/// `CFBundleVersion` in the Info.plist with the values its version file names.
/// A literal in the plist that differs, such as `<string>3.1</string>` when the
/// version is `3.1.0`, would be dropped without a word. So the build fails
/// instead, and says what to set.
///
/// A key passes when it is absent; when it is a version variable, either the
/// one `flutter create` writes (`$(FLUTTER_BUILD_NAME)` and
/// `$(FLUTTER_BUILD_NUMBER)`, in the iOS and the macOS template alike) or
/// Xcode's own (`$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`), in
/// either spelling; when it already is the value the version gives it; and
/// when the version file does not name it, since rules_apple then keeps the
/// plist's value. The plist may be XML or binary.
///
/// The value each key ends up with, the version file's or else the plist's
/// literal, must be the one the `flutter_application` gives it
/// (`--short-version-string`, `--build-version`): the program reports that
/// version as `appBuildName` and `appBuildNumber`, and a bundle that said
/// otherwise would ship two. The version file of a rules_apple
/// `apple_bundle_version` may be written from `--embed_label`, so this is
/// known only here. `--short-version-string-setting` and
/// `--build-version-setting` name the build setting that gave a value, such as
/// `--@rules_flutter//flutter:build_number`, which a version that states its
/// own values cannot follow.
///
/// On success the tool writes `--stamp`, which the build requires so that a
/// plist that fails the check fails the build.
///
/// It has no package dependencies beyond its siblings `merge_plists.dart` and `plist_binary.dart`, and
/// runs with the bare Dart SDK.
///
/// Usage:
///   dart check_apple_version_keys.dart --plist <file> --name <shown name>
///       --version-file <rules_apple version file> --version-target <label>
///       --app <label> --rule <macro> --application <label>
///       --short-version-string <value> --build-version <value>
///       [--short-version-string-setting <flag>] [--build-version-setting <flag>]
///       --stamp <file>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'merge_plists.dart';

/// A version key: the variables that stand for it, the field of rules_apple's
/// version file that sets it, the macro argument that sets that field, and
/// the getter the program reads the same value with.
class VersionKey {
  final String key;

  /// The variable `flutter create` writes, then Xcode's own.
  final List<String> variables;
  final String versionField;
  final String argument;
  final String reportedAs;

  const VersionKey(
    this.key,
    this.variables,
    this.versionField,
    this.argument,
    this.reportedAs,
  );
}

const versionKeys = [
  VersionKey(
    'CFBundleShortVersionString',
    ['FLUTTER_BUILD_NAME', 'MARKETING_VERSION'],
    'short_version_string',
    'build_name',
    'appBuildName',
  ),
  VersionKey(
    'CFBundleVersion',
    ['FLUTTER_BUILD_NUMBER', 'CURRENT_PROJECT_VERSION'],
    'build_version',
    'build_number',
    'appBuildNumber',
  ),
];

/// A value read from a plist: its [text] when it is a string, and how to show
/// it in a message.
class PlistValue {
  final String? text;
  final String shown;

  const PlistValue.string(String value) : text = value, shown = '"$value"';
  const PlistValue.other(this.shown) : text = null;
}

String _decodeEntities(String s) => s.replaceAllMapped(
  RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'),
  (m) {
    final e = m[1]!;
    if (e.startsWith('#x')) {
      return String.fromCharCode(int.parse(e.substring(2), radix: 16));
    }
    if (e.startsWith('#'))
      return String.fromCharCode(int.parse(e.substring(1)));
    return const {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
    }[e]!;
  },
);

/// The root dictionary's [PlistValue] for each of [wanted] it declares, from an
/// XML plist.
Map<String, PlistValue> readXmlValues(
  String xml,
  String name,
  Set<String> wanted,
) {
  final values = <String, PlistValue>{};
  for (final entry in parsePlist(xml, name)) {
    if (!wanted.contains(entry.key)) continue;
    final raw = entry.rawValue.trim();
    final match = RegExp(
      r'^<string>(.*)</string>$',
      dotAll: true,
    ).firstMatch(raw);
    if (match != null) {
      values[entry.key] = PlistValue.string(_decodeEntities(match[1]!));
    } else if (raw == '<string/>') {
      values[entry.key] = const PlistValue.string('');
    } else {
      values[entry.key] = PlistValue.other(raw);
    }
  }
  return values;
}

/// Whether [value] is [variable] in either of the spellings Xcode expands.
bool isVariable(String value, String variable) =>
    value == '\$($variable)' || value == '\${$variable}';

/// The problems with the version keys of the plist whose bytes are [bytes], one
/// message each; empty when it is good. [name] is the plist as the user knows it,
/// [version] the decoded version file rules_apple reads, [app] the app's label
/// and [rule] the macro that declares it.
List<String> versionKeyProblems({
  required Uint8List bytes,
  required String name,
  required Map<String, Object?> version,
  required String app,
  required String rule,
}) {
  final wanted = {for (final k in versionKeys) k.key};
  final values = readXmlValues(plistXml(bytes, name), name, wanted);
  final problems = <String>[];
  for (final k in versionKeys) {
    final value = values[k.key];
    final replacement = version[k.versionField];
    // rules_apple sets a key only when the version file gives it a value.
    if (value == null || replacement is! String || replacement.isEmpty) {
      continue;
    }
    final text = value.text;
    if (text != null &&
        (text == replacement ||
            k.variables.any((variable) => isVariable(text, variable)))) {
      continue;
    }
    problems.add(
      'ERROR: $name sets ${k.key} to ${value.shown}, and $app would '
      'silently replace it with "$replacement": $rule gives rules_apple a '
      'version that sets ${k.key}.\n'
      '  To set the version, pass `${k.argument}` to $rule (or `version` '
      'with an apple_bundle_version target), and delete ${k.key} from the '
      'plist or leave it as \$(${k.variables.first}), as `flutter create` '
      'writes it.',
    );
  }
  return problems;
}

/// The problems with the version the bundle of [app] ends up with, one message
/// each; empty when it is the program's. [version] is the decoded version
/// file of [versionTarget], [bytes] the plist named [name], [expected]
/// the value of each key that [application] gives it, and [settings] the
/// build setting that gave a key's value, where one did.
List<String> versionAgreementProblems({
  required Uint8List bytes,
  required String name,
  required Map<String, Object?> version,
  required String versionTarget,
  required String app,
  required String application,
  required Map<String, String> expected,
  Map<String, String> settings = const {},
}) {
  final wanted = {for (final k in versionKeys) k.key};
  final values = readXmlValues(plistXml(bytes, name), name, wanted);
  final problems = <String>[];
  for (final k in versionKeys) {
    final want = expected[k.key]!;
    final replacement = version[k.versionField];
    final String? bundle;
    final String from;
    if (replacement is String && replacement.isNotEmpty) {
      bundle = replacement;
      from = 'its version $versionTarget gives ${k.key} "$replacement"';
    } else {
      final text = values[k.key]?.text;
      final literal =
          text != null &&
          !k.variables.any((variable) => isVariable(text, variable));
      bundle = literal ? text : null;
      from = literal
          ? 'its version $versionTarget gives no ${k.key}, so the bundle '
                'keeps "$text" from $name'
          : 'its version $versionTarget gives no ${k.key}';
    }
    if (bundle == want) continue;
    final setting = settings[k.key];
    problems.add(
      setting != null
          ? 'ERROR: The bundle of $app would not report the version its '
                'program does: $from, and `$setting` gives the application '
                '$application "$want" for this build (its `${k.argument}`, as '
                '`${k.reportedAs}`).\n'
                '  Give $versionTarget `application = "$application"` if it is '
                'a flutter_apple_bundle_version, so that it follows the '
                'setting: a version that states its own values cannot.'
          : 'ERROR: The bundle of $app would not report the version its program '
                'does: $from, and the application $application reports "$want" '
                '(its `${k.argument}`, as `${k.reportedAs}`).\n'
                '  Give $versionTarget `application = "$application"` if it is a '
                'flutter_apple_bundle_version, or set the version on the application '
                'to the one the bundle should carry.',
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
    'plist',
    'name',
    'version-file',
    'version-target',
    'app',
    'rule',
    'application',
    'short-version-string',
    'build-version',
    'stamp',
  ]) {
    if (!options.containsKey(required)) {
      stderr.writeln('ERROR: missing --$required.');
      return 2;
    }
  }
  final List<String> problems;
  try {
    final bytes = File(options['plist']!).readAsBytesSync();
    final version = jsonDecode(
      File(options['version-file']!).readAsStringSync(),
    ) as Map<String, Object?>;
    problems = [
      ...versionKeyProblems(
        bytes: bytes,
        name: options['name']!,
        version: version,
        app: options['app']!,
        rule: options['rule']!,
      ),
      ...versionAgreementProblems(
        bytes: bytes,
        name: options['name']!,
        version: version,
        versionTarget: options['version-target']!,
        app: options['app']!,
        application: options['application']!,
        expected: {
          'CFBundleShortVersionString': options['short-version-string']!,
          'CFBundleVersion': options['build-version']!,
        },
        settings: {
          if (options['short-version-string-setting'] case final setting?)
            'CFBundleShortVersionString': setting,
          if (options['build-version-setting'] case final setting?)
            'CFBundleVersion': setting,
        },
      ),
    ];
  } on PlistFormatException catch (e) {
    stderr.writeln('ERROR: ${options['name']} cannot be read as a plist: $e');
    return 1;
  }
  if (problems.isNotEmpty) {
    stderr.writeln(problems.join('\n'));
    return 1;
  }
  File(options['stamp']!).writeAsStringSync('');
  return 0;
}

void main(List<String> args) => exit(run(args));
