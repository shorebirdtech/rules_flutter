/// Verifies the iOS registrant of an app that depends on
/// `package:integration_test` registers its plugin.
///
/// Property: `integration_test` is a Flutter SDK package, built from the pinned
/// Flutter source, and its `flutter.plugin` block reaches the app like any
/// hosted plugin's: the generated registrant calls
/// `IntegrationTestPlugin.register(...)`. A plugin that compiled into the app
/// but was never registered would never run.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

void main() {
  final registrant = File(
    requireRunfile(
      'integration_ios_registrant_native_plugin_registrant.swift',
      what: 'The generated iOS registrant',
    ),
  ).readAsStringSync();

  const registration =
      'IntegrationTestPlugin.register(with: '
      'registry.registrar(forPlugin: "IntegrationTestPlugin")';
  if (!registrant.contains(registration)) {
    stderr.writeln(
      'The iOS registrant does not register IntegrationTestPlugin '
      '(expected `$registration`):\n$registrant',
    );
    exit(1);
  }
  stdout.writeln('The iOS registrant registers IntegrationTestPlugin.');
}
