/// Checks that an app's Info.plist leaves its version keys to `build_name` and
/// `build_number`.
///
/// `flutter_ios_app` and `flutter_macos_app` always give rules_apple a version,
/// and rules_apple then replaces `CFBundleShortVersionString` and
/// `CFBundleVersion` in the Info.plist with it. A literal in the plist, such as
/// `<string>3.1</string>`, would be dropped without a word. So the build fails
/// instead, and says what to set.
///
/// The keys are allowed absent, or set to the variable `flutter create` writes
/// (`$(FLUTTER_BUILD_NAME)` and `$(FLUTTER_BUILD_NUMBER)`, in the iOS and the
/// macOS template alike) or its `${...}` spelling. The plist may be XML or
/// binary.
///
/// On success the tool writes `--stamp`, which the build requires so that a
/// plist that fails the check fails the build.
///
/// It has no package dependencies beyond its siblings `merge_plists.dart` and `plist_binary.dart`, and
/// runs with the bare Dart SDK.
///
/// Usage:
///   dart check_apple_version_keys.dart --plist <file> --name <shown name>
///       --app <label> --rule <macro> --stamp <file>
import 'dart:io';
import 'dart:typed_data';

import 'merge_plists.dart';

/// A version key's variable, and the macro argument that sets the key.
class VersionKey {
  final String key;
  final String variable;
  final String argument;

  const VersionKey(this.key, this.variable, this.argument);
}

const versionKeys = [
  VersionKey('CFBundleShortVersionString', 'FLUTTER_BUILD_NAME', 'build_name'),
  VersionKey('CFBundleVersion', 'FLUTTER_BUILD_NUMBER', 'build_number'),
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
/// [app] the app's label and [rule] the macro that declares it.
List<String> versionKeyProblems({
  required Uint8List bytes,
  required String name,
  required String app,
  required String rule,
}) {
  final wanted = {for (final k in versionKeys) k.key};
  final values = readXmlValues(plistXml(bytes, name), name, wanted);
  final problems = <String>[];
  for (final k in versionKeys) {
    final value = values[k.key];
    if (value == null ||
        (value.text != null && isVariable(value.text!, k.variable))) {
      continue;
    }
    problems.add(
      'ERROR: $name sets ${k.key} to ${value.shown}, and $app would '
      'silently drop it: $rule gives rules_apple a version that replaces '
      '${k.key}.\n'
      '  To set the version, pass `${k.argument}` to $rule (or `version` '
      'with an apple_bundle_version target), and delete ${k.key} from the '
      'plist or leave it as \$(${k.variable}), as `flutter create` writes '
      'it.',
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
  for (final required in ['plist', 'name', 'app', 'rule', 'stamp']) {
    if (!options.containsKey(required)) {
      stderr.writeln('ERROR: missing --$required.');
      return 2;
    }
  }
  final List<String> problems;
  try {
    problems = versionKeyProblems(
      bytes: File(options['plist']!).readAsBytesSync(),
      name: options['name']!,
      app: options['app']!,
      rule: options['rule']!,
    );
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
