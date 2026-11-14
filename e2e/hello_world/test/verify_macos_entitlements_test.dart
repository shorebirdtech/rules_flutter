/// Verifies the entitlements blob applied at codesign time on the macOS
/// bundle produced by `:hello_world_macos` (which uses the Tier-1
/// `flutter_macos_app` macro).
///
/// `flutter create --platforms=macos .` always emits
/// `macos/Runner/{DebugProfile,Release}.entitlements`. Both files declare
/// the App Sandbox capability (`com.apple.security.app-sandbox`). The
/// macro auto-discovers the conventional pair and forwards them to
/// `macos_application(entitlements = ...)`, so codesign embeds the
/// merged plist into the bundle and macOS treats the app as sandboxed
/// at runtime — meaning `getApplicationDocumentsDirectory()` returns
/// `~/Library/Containers/<bundle-id>/Data/Documents/` instead of
/// `~/Documents/`, matching `flutter build macos`.
///
/// This test reads `codesign -d --entitlements -` and asserts the
/// sandbox key is present.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'hello_world_macos.zip',
    appName: 'Hello World',
    prefix: 'hello_world_macos_entitlements_',
  );
  try {
    final check = bundle.check..exists('.app bundle', bundle.path);
    if (check.ok) {
      final entitlements = Entitlements.fromSignature(bundle.path);
      stdout
        ..writeln('--- codesign --entitlements --- ')
        ..writeln(entitlements.blob)
        ..writeln('--- end ---');
      check.expect(
        'sandbox entitlement present',
        condition: entitlements.declares('com.apple.security.app-sandbox'),
        detail:
            'expected entitlements blob to declare '
            'com.apple.security.app-sandbox. Got:\n'
            '${entitlements.blob.isEmpty ? '<empty>' : entitlements.blob}',
      );
    }
    bundle.finish('PASS — sandbox entitlement present.');
  } finally {
    bundle.dispose();
  }
}
