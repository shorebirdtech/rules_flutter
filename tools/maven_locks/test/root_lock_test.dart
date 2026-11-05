/// What the root `rules_android_maven_install.json`, the lock every consumer
/// of rules_flutter gets, must hold.
///
/// androidx.lifecycle is released as one version group: `lifecycle-runtime`
/// 2.10.0 is built against `lifecycle-livedata-core` and `-viewmodel-savedstate`
/// of 2.10.0, and Gradle, which the plugins are written against, resolves the
/// group to one version. Coursier with relaxed reconciliation resolves without
/// error even when the group is left to be pulled in transitively, but then
/// takes the old version some other artifact asks for (livedata 2.0.0,
/// savedstate 1.2.1), a mix that no release was tested as. The root
/// `maven.install` names the members `fragment` pulls in at 2.10.0 so they
/// stay together; a lock where they differ means one of those lines went.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  final runfiles = Runfiles.create(
    sourceRepository: Platform.environment['RUNFILES_SOURCE_REPO'] ?? '',
  );
  final lock = jsonDecode(
    File(
      runfiles.rlocation(Platform.environment['ROOT_LOCK']!),
    ).readAsStringSync(),
  ) as Map<String, dynamic>;
  final artifacts = (lock['artifacts'] as Map).cast<String, Map>();

  test('the androidx.lifecycle artifacts share one version', () {
    final versions = {
      for (final entry in artifacts.entries)
        if (entry.key.startsWith('androidx.lifecycle:'))
          entry.key: entry.value['version'] as String,
    };
    expect(versions, isNotEmpty);
    expect(
      versions.values.toSet(),
      hasLength(1),
      reason: 'versions in the lock: $versions',
    );
  });

  test('androidx.savedstate matches the lifecycle group that needs it', () {
    // lifecycle 2.10.0 asks for savedstate 1.4.0.
    final savedstate = {
      for (final entry in artifacts.entries)
        if (entry.key.startsWith('androidx.savedstate:'))
          entry.key: entry.value['version'] as String,
    };
    expect(savedstate, isNotEmpty);
    expect(savedstate.values.toSet(), {'1.4.0'});
  });
}
