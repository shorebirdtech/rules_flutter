/// Verifies that `:second_app`, which ships this package's `flutter create`
/// runner under an application id of its own, names launch activities its
/// dex actually defines.
///
/// `MainActivity.kt` declares `package com.example.flutterapp`, which the app
/// gives as its `namespace`; the manifest names `.MainActivity`. Android
/// separates the code's package from the application id, and a relative class
/// name belongs to the former. Resolved against the application id instead, the
/// APK names `com.example.flutterapp.second.MainActivity`, which does not
/// exist, and the app dies on launch with a ClassNotFoundException.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/apk_contents.dart';

const _applicationId = 'com.example.flutterapp.second';

void main() {
  final apk = Apk.fromRunfiles('second_app.apk', prefix: 'android_second_app');
  final check = apk.check;
  final elements = manifestElements(apk.manifest.readAsBytesSync());
  final package = elements.first.attributes['package'];
  final activities = [
    for (final e in elements)
      if (e.name == 'activity') e.attributes['name']!,
  ];
  final classes = apk.definedClasses();

  print('Application id: $package');
  check
    ..expect(
      'application id is $_applicationId',
      condition: package == _applicationId,
      detail: 'expected application id $_applicationId',
    )
    ..expect(
      'the manifest declares an activity',
      condition: activities.isNotEmpty,
      detail: 'the manifest declares no activity',
    );
  for (final activity in activities) {
    final descriptor = 'L${activity.replaceAll('.', '/')};';
    check.expect(
      'activity $activity is defined in dex',
      condition: classes.contains(descriptor),
      detail:
          'the manifest names activity $activity, which no dex '
          'defines. Dex activities: '
          '${classes.where((c) => c.endsWith('Activity;')).join(', ')}',
    );
  }
  apk.finish('All second app checks passed.');
}
