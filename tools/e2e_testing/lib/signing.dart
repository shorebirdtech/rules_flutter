/// What a built Apple bundle's code signature and binaries declare.
library;

import 'dart:convert';
import 'dart:io';

import 'bundle_check.dart';
import 'plist.dart';

/// The entitlements a bundle or binary carries.
class Entitlements {
  Entitlements._(this.blob, this.values);

  /// The entitlements `codesign` embedded in [bundle]'s signature.
  ///
  /// Throws a [ProcessException] if `codesign` fails.
  factory Entitlements.fromSignature(String bundle) {
    final result = Process.runSync(
      'codesign',
      ['-d', '--entitlements', ':-', bundle],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'codesign',
        ['-d', '--entitlements', ':-', bundle],
        result.stderr.toString(),
        result.exitCode,
      );
    }
    return Entitlements.parse(result.stdout as String);
  }

  /// The entitlements linked into [binary]'s `__TEXT,__entitlements` section.
  ///
  /// A simulator build is signed ad hoc, so its entitlements are not in the
  /// code signature: rules_apple links them into the binary instead, which is
  /// where the simulator reads them.
  ///
  /// Throws a [ProcessException] if the binary has no such section.
  factory Entitlements.fromBinarySection(String binary) {
    final dir = Directory.systemTemp.createTempSync('entitlements');
    try {
      final out = '${dir.path}/entitlements.plist';
      final args = [binary, '-extract', '__TEXT', '__entitlements', out];
      final result = Process.runSync('segedit', args);
      if (result.exitCode != 0) {
        throw ProcessException(
          'segedit',
          args,
          result.stderr.toString(),
          result.exitCode,
        );
      }
      return Entitlements.parse(File(out).readAsStringSync());
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// The entitlements in the XML plist [blob]. An empty blob, which is what
  /// `codesign` prints for a bundle signed with none, declares nothing.
  factory Entitlements.parse(String blob) => Entitlements._(
    blob,
    blob.trim().isEmpty ? const {} : Plist.parseXml(blob).values,
  );

  /// The XML plist as `codesign` printed it.
  final String blob;

  /// The entitlements by key.
  final Map<String, Object?> values;

  /// Whether the key [name] is declared, whatever its value.
  bool declares(String name) => values.containsKey(name);

  /// Whether [name] is declared and true.
  bool isEnabled(String name) => values[name] == true;

  /// The App Groups declared, or null if the key is missing or not a list.
  List<Object?>? get applicationGroups {
    final groups = values['com.apple.security.application-groups'];
    return groups is List ? groups : null;
  }

  /// Passes if [owner] declares [group] among its App Groups.
  void checkInGroup(BundleCheck check, String owner, String group) {
    check.expect(
      '$owner is in $group',
      condition: applicationGroups?.contains(group) ?? false,
      detail: '$owner has App Groups $applicationGroups, expected $group',
    );
  }
}

/// The code signature on a bundle.
class CodeSignature {
  /// The signature on [bundle], an `.app` or `.appex` directory.
  const CodeSignature(this.bundle);

  /// The bundle directory.
  final String bundle;

  /// Passes if `codesign --verify --deep --strict` accepts the bundle and
  /// everything nested in it.
  void checkValid(BundleCheck check) => check.command(
    'codesign --verify --deep --strict',
    'codesign',
    ['--verify', '--deep', '--strict', bundle],
    (_) => true,
  );

  /// The team that signed the bundle, or null if it is signed ad hoc.
  String? get teamIdentifier {
    // codesign -d writes its report to stderr.
    final result = Process.runSync('codesign', [
      '-dv',
      bundle,
    ], stderrEncoding: utf8);
    return parseTeamIdentifier(result.stderr as String);
  }

  /// The team named in a `codesign -dv` [report], or null if the report has
  /// none or says `not set`, which is what an ad hoc signature prints.
  static String? parseTeamIdentifier(String report) {
    final team = RegExp(
      r'^TeamIdentifier=(.+)$',
      multiLine: true,
    ).firstMatch(report)?.group(1);
    return team == null || team == 'not set' ? null : team;
  }
}
