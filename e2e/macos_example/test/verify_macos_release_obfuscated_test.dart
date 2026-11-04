/// Property: an app built with `obfuscate = True` does not carry its Dart
/// class names in the `App` binary it ships.
///
/// The names an attacker reads are in the symbol table as well as the
/// snapshot, so both are searched. The unobfuscated app is the control: it
/// names `MyApp` in its binary, so the
/// obfuscated one lacking the name is the obfuscation, not a binary that
/// never held names to begin with.
///
/// Run once for each `-c` that builds Flutter's release mode (see the BUILD
/// file): obfuscating must not depend on which of them was asked for.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/mach_o.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

/// The Dart class `lib/main.dart` declares.
const _identifier = 'MyApp';

/// Whether the file at [path] names [_identifier] in its symbol table or in
/// any printable string.
bool _names(String path) {
  final strings = Process.runSync('strings', ['-a', path]);
  return MachO(path).hasSymbolContaining(_identifier) ||
      (strings.exitCode == 0 &&
          strings.stdout.toString().contains(_identifier));
}

void main() {
  final plain = MacosBundle.fromRunfiles(
    'app.zip',
    appName: 'Flutter App',
    prefix: 'plain_bundle_test',
  );
  final obfuscated = MacosBundle.fromRunfiles(
    'app_obfuscated.zip',
    appName: 'Flutter App',
    prefix: 'obfuscated_bundle_test',
  );
  try {
    const binary = 'App.framework/App';
    plain.check.expect(
      'control: the unobfuscated App binary names $_identifier',
      condition: _names('${plain.frameworks}/$binary'),
      detail:
          'the control binary does not hold $_identifier either, so the '
          'check below proves nothing',
    );
    plain.check.expect(
      'the obfuscated App binary does not name $_identifier',
      condition: !_names('${obfuscated.frameworks}/$binary'),
      detail: '$_identifier is in the binary of a build with obfuscate = True',
    );
    plain.finish('The obfuscated App binary holds no Dart class names.');
  } finally {
    plain.dispose();
    obfuscated.dispose();
  }
}
