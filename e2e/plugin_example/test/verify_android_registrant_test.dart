/// Verifies the Android registrant of `plugin_app` registers the plugin of
/// `kotlin_only_plugin`.
///
/// Property: a `path` package with no Bazel build, named in
/// `flutter_pub.from_lock(build_from_pubspec = ...)`, is built from its
/// pubspec as a plugin from pub.dev is: its `pluginClass` and `package` reach
/// the app, and the generated registrant adds the plugin to the engine. A
/// plugin that compiled into the app but was never registered would never
/// answer its channel.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

void main() {
  final registrant = File(
    requireRunfile(
      'plugin_android_registrant/io/flutter/plugins/GeneratedPluginRegistrant.java',
      what: 'The generated Android registrant',
    ),
  ).readAsStringSync();

  const registration = 'new com.example.kotlin_only_plugin.KotlinOnlyPlugin()';
  if (!registrant.contains(registration)) {
    stderr.writeln(
      'The Android registrant does not register KotlinOnlyPlugin '
      '(expected `$registration`):\n$registrant',
    );
    exit(1);
  }
  stdout.writeln('The Android registrant registers KotlinOnlyPlugin.');
}
