/// Verifies `:app_release`, the `flutter_android_release` of `:app_bundle`, by
/// running it as `bazel run` would, with a keystore the test makes for itself.
///
/// - `create-key` makes the keystore `key.properties` names, and refuses to
///   replace it or to make one whose two passwords differ.
/// - `sign` fails, writing nothing, without a keystore, with a wrong password
///   and with an alias the keystore lacks.
/// - `sign` writes `app-release.aab` and `app-release.apk`. The bundle is
///   signed by the test's key alone and passes `bundletool validate`; the APK
///   verifies with the SDK's `apksigner` (v2) against the same certificate and
///   is 16 KB-aligned, its native libraries stored uncompressed.
/// - Both are release builds for all three default ABIs, though the test is not
///   built with `-c opt`: AOT `libapp.so` for armeabi-v7a, arm64-v8a and
///   x86_64, no kernel snapshot, a manifest that is not debuggable, and dex
///   shrunk by R8 (the bundle carries R8's mapping) with no core library
///   desugaring runtime in it.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/apk_contents.dart';
import 'package:rules_flutter_e2e_testing/archive.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/zip_entries.dart';
import 'package:runfiles/runfiles.dart';

const _password = 'release-test-password';
const _alias = 'upload';
// The ABIs `flutter build apk` and `flutter build appbundle` build for by
// default.
const _abis = ['armeabi-v7a', 'arm64-v8a', 'x86_64'];

final _runfiles = Runfiles.create();
final _check = BundleCheck();

String _runfile(String env) {
  final key = Platform.environment[env];
  if (key == null || key.isEmpty) {
    stderr.writeln('$env is not set');
    exit(1);
  }
  return _runfiles.rlocation(key);
}

final Map<String, Object?> _config = jsonDecode(
  File(_runfile('RELEASE_CONFIG_RUNFILE')).readAsStringSync(),
) as Map<String, Object?>;

String _tool(String name) => _runfiles.rlocation(_config[name]! as String);

ProcessResult _release(List<String> args) {
  final environment = Map.of(Platform.environment)
    ..remove('BUILD_WORKSPACE_DIRECTORY')
    ..remove('BUILD_WORKING_DIRECTORY')
    ..['RULES_FLUTTER_ANDROID_RELEASE_CONFIG'] =
        Platform.environment['RELEASE_CONFIG_RUNFILE']!;
  return Process.runSync(
    _runfile('RELEASE_RUNFILE'),
    args,
    environment: environment,
    includeParentEnvironment: false,
  );
}

ProcessResult _run(String executable, List<String> args) =>
    Process.runSync(executable, args);

String _output(ProcessResult result) => '${result.stdout}${result.stderr}';

List<String> _fingerprints(String keytoolOutput) => [
  for (final m in RegExp(r'SHA256:\s*([0-9A-F:]+)').allMatches(keytoolOutput))
    m.group(1)!,
];

void main() {
  final tmp = Directory(
    Platform.environment['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  ).createTempSync('release_');
  final keystore = '${tmp.path}/upload.jks';
  final keyProperties = '${tmp.path}/key.properties';
  final out = '${tmp.path}/out';
  final aab = '$out/app-release.aab';
  final apk = '$out/app-release.apk';

  void writeProperties({
    String store = _password,
    String key = _password,
    String alias = _alias,
  }) => File(keyProperties).writeAsStringSync(
    '# Written by the test.\n'
    'storePassword=$store\n'
    'keyPassword=$key\n'
    'keyAlias=$alias\n'
    // A backslash in a .properties value starts an escape, and the temp
    // directory is joined with them on Windows (`\r` of `\release_...` would
    // read as a carriage return), so they are written escaped, as a
    // key.properties on Windows has to be.
    'storeFile=${keystore.replaceAll(r'\', r'\\')}\n',
  );

  final sign = ['--key-properties=$keyProperties', '--output-dir=$out'];

  void expectRefused(String what, ProcessResult result, String mentions) {
    final output = _output(result);
    _check
      ..expect(
        '$what fails',
        condition: result.exitCode == 1,
        detail: 'exit ${result.exitCode}:\n$output',
      )
      ..expect(
        '$what says "$mentions"',
        condition: output.contains(mentions),
        detail: output,
      )
      ..expect(
        '$what writes no release',
        condition: !File(aab).existsSync() && !File(apk).existsSync(),
        detail: 'found output in $out',
      );
  }

  // Refusals before a keystore exists.
  writeProperties();
  expectRefused('sign without a keystore', _release(sign), 'create-key');
  writeProperties(key: 'another-password');
  expectRefused(
    'create-key with two passwords',
    _release(['create-key', '--key-properties=$keyProperties']),
    'differ',
  );
  _check.expect(
    'the refused create-key made no keystore',
    condition: !File(keystore).existsSync(),
  );

  // The key.
  writeProperties();
  final created = _release(['create-key', '--key-properties=$keyProperties']);
  _check.expect(
    'create-key succeeds',
    condition: created.exitCode == 0 && File(keystore).existsSync(),
    detail: _output(created),
  );
  final keystoreBytes = File(keystore).readAsBytesSync();
  expectRefused(
    'a second create-key',
    _release(['create-key', '--key-properties=$keyProperties']),
    'already exists',
  );
  _check.expect(
    'the second create-key left the keystore alone',
    condition: _sameBytes(File(keystore).readAsBytesSync(), keystoreBytes),
  );
  final listing = _run(_tool('keytool'), [
    '-J-Duser.language=en',
    '-list',
    '-v',
    '-keystore',
    keystore,
    '-storepass',
    _password,
  ]);
  final fingerprint = _fingerprints(_output(listing)).firstOrNull;
  _check.expect(
    'keytool reads the certificate fingerprint',
    condition: fingerprint != null,
    detail: _output(listing),
  );

  // Refusals with a keystore.
  writeProperties(store: 'wrong-password', key: 'wrong-password');
  expectRefused('sign with a wrong password', _release(sign), 'password');
  writeProperties(alias: 'nobody');
  expectRefused('sign with an unknown alias', _release(sign), 'nobody');

  // The release.
  writeProperties();
  final signed = _release(sign);
  print(_output(signed));
  _check
    ..expect(
      'sign succeeds',
      condition: signed.exitCode == 0,
      detail: _output(signed),
    )
    ..exists('the signed bundle', aab, nonEmpty: true)
    ..exists('the signed APK', apk, nonEmpty: true);

  // The bundle's signature.
  final verified = _run(_tool('jarsigner'), [
    '-J-Duser.language=en',
    '-verify',
    aab,
  ]);
  _check.expect(
    'jarsigner verifies the bundle',
    condition:
        verified.exitCode == 0 && _output(verified).contains('jar verified.'),
    detail: _output(verified),
  );
  final printcert = _run(_tool('keytool'), [
    '-J-Duser.language=en',
    '-printcert',
    '-jarfile',
    aab,
  ]);
  final bundleSigners = _fingerprints(_output(printcert));
  _check.expect(
    "the bundle's only signer is the test's key",
    condition: bundleSigners.length == 1 && bundleSigners.single == fingerprint,
    detail: 'signers $bundleSigners, key $fingerprint',
  );
  final validated = _run(_tool('java'), [
    '-jar',
    _tool('bundletool'),
    'validate',
    '--bundle=$aab',
  ]);
  _check.expect(
    'bundletool validates the bundle',
    condition: validated.exitCode == 0,
    detail: _output(validated),
  );

  // The bundle's contents.
  final bundle = ExtractedArchive.fromPath(
    aab,
    prefix: 'release_aab',
    extractor: Extractor.zipper,
  );
  for (final abi in _abis) {
    for (final lib in ['libapp.so', 'libflutter.so', 'libadd.so']) {
      _check.exists(
        '$abi $lib in the bundle',
        '${bundle.path}/base/lib/$abi/$lib',
      );
    }
  }
  _check
    ..absent(
      'kernel_blob.bin',
      '${bundle.path}/base/assets/flutter_assets/kernel_blob.bin',
    )
    ..exists(
      "R8's mapping in the bundle",
      '${bundle.path}/BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map',
      nonEmpty: true,
    );
  final bundleManifest = _run(_tool('java'), [
    '-jar',
    _tool('bundletool'),
    'dump',
    'manifest',
    '--bundle=$aab',
  ]);
  _check.expect(
    "the bundle's manifest is not debuggable",
    condition:
        bundleManifest.exitCode == 0 &&
        !_output(bundleManifest).contains('android:debuggable="true"'),
    detail: _output(bundleManifest),
  );

  // The APK's signature and alignment.
  final apkCerts = _run(_runfile('APKSIGNER_RUNFILE'), [
    'verify',
    '--print-certs',
    '-v',
    apk,
  ]);
  final apkOutput = _output(apkCerts);
  final apkSigners = [
    for (final m in RegExp(
      r'Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)',
    ).allMatches(apkOutput))
      m.group(1)!,
  ];
  final expected = fingerprint?.replaceAll(':', '').toLowerCase();
  _check
    ..expect(
      'apksigner verifies the APK with scheme v2',
      condition:
          apkCerts.exitCode == 0 &&
          apkOutput.contains(
            'Verified using v2 scheme (APK Signature Scheme v2): true',
          ),
      detail: apkOutput,
    )
    ..expect(
      "the APK's only signer is the test's key",
      condition: apkSigners.length == 1 && apkSigners.single == expected,
      detail: 'signers $apkSigners, key $expected',
    );
  final aligned = _run(_runfile('ZIPALIGN_RUNFILE'), [
    '-c',
    '-P',
    '16',
    '4',
    apk,
  ]);
  _check.expect(
    'the APK is 16 KB-aligned',
    condition: aligned.exitCode == 0,
    detail: _output(aligned),
  );

  // The APK's contents.
  final extracted = Apk(
    ExtractedArchive.fromPath(
      apk,
      prefix: 'release_apk',
      extractor: Extractor.zipper,
    ),
    apkFile: apk,
    check: _check,
  );
  _check.expect(
    'the APK carries both ABIs',
    condition: _abis.every(extracted.abis.contains),
    detail: 'ABIs ${extracted.abis}',
  );
  for (final abi in _abis) {
    for (final lib in ['libapp.so', 'libflutter.so', 'libadd.so']) {
      _check.exists(
        '$abi $lib in the APK',
        '${extracted.path}/lib/$abi/$lib',
      );
    }
  }
  extracted
    ..checkNativeLibrariesUncompressed()
    ..checkNoMultiplatformMetadata()
    ..checkNoCoreLibraryDesugaring();
  final bundleMetadata = [
    for (final entry in zipEntries(File(aab).readAsBytesSync()))
      if (RegExp('^base/root/[A-Za-z0-9]+Main/default/').hasMatch(entry.name))
        entry.name,
  ];
  _check.expect(
    'no Kotlin Multiplatform metadata in the bundle',
    condition: bundleMetadata.isEmpty,
    detail:
        '${bundleMetadata.length} entries, such as '
        '${bundleMetadata.take(5).join(', ')}',
  );
  final root = manifestElements(extracted.manifest.readAsBytesSync());
  final debuggable = [
    for (final e in root)
      if (e.name == 'application') e.attributes['debuggable'],
  ];
  _check
    ..expect(
      "the APK's manifest is not debuggable",
      condition: !debuggable.contains('true'),
      detail: 'android:debuggable $debuggable',
    )
    ..finish('All release checks passed.');
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
