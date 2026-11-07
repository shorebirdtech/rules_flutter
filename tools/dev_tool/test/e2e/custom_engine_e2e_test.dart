/// An app built against a framework and an engine that are not the release's.
///
/// **The properties** (`e2e/custom_engine`, whose checkout is the official
/// artifacts laid out as a flutter/flutter checkout with engine out dirs):
///
///  1. Built with the SDK that names the checkout, in release and in debug, the
///     macOS app carries `flutter_assets/flutter_sdk.json`: the out dirs and the
///     checkout it came from, the snapshot hash and the kernel format, and no
///     path of the machine that built it.
///  2. The release's apps carry no such file.
///  3. A gen_snapshot of another Dart than the engine's fails the build, naming
///     both and their hashes.
///  4. A checkout given by `--repo_env=FLUTTER_CHECKOUT` works; not set, the
///     repositories still load (`bazel query`) and a build that selects the SDK
///     says what to set.
///  5. The iOS simulator app (debug) and the iOS device framework (release) are
///     built from the checkout's `ios_debug_sim_arm64` and `ios_release` out
///     dirs and record them.
///  6. The Android APK is built from the checkout's `android_<mode>_<cpu>` out
///     dirs for each ABI it carries, and records the first ABI's.
///  7. The iOS device framework and the Android APK refuse a gen_snapshot of
///     another Dart, as the macOS app does.
@Tags(['e2e'])
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _sdkFlag = '--@rules_flutter//flutter:sdk=';

/// The stock Dart's snapshot hash, which the stand-in's engine and
/// gen_snapshot carry.
const _snapshotHash = '0451907c2eaa8467e848c0067bfe8ed4';

String get _workspace {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'MODULE.bazel')).existsSync() ||
      !Directory(p.join(dir.path, 'e2e', 'custom_engine')).existsSync()) {
    dir = dir.parent;
  }
  return p.join(dir.path, 'e2e', 'custom_engine');
}

Future<ProcessResult> _bazel(List<String> args) => Process.run('bazel', [
  ...args,
  '--noshow_progress',
  '--curses=no',
  '--color=no',
], workingDirectory: _workspace);

/// The `flutter_sdk.json` that [target] built with [sdk] and [extra] carries, or
/// null when it has none: in an archive of the app (`.zip`, `.ipa`, `.apk`) or in
/// the files it is made of.
Future<Map<String, Object?>?> _record(
  String sdk,
  List<String> extra, {
  String target = '//:app',
}) async {
  final build = await _bazel(['build', target, '$_sdkFlag$sdk', ...extra]);
  expect(build.exitCode, 0, reason: '${build.stderr}');
  final files = await _bazel([
    'cquery',
    target,
    '$_sdkFlag$sdk',
    ...extra,
    '--output=files',
  ]);
  final out = Directory.systemTemp.createTempSync('custom_engine');
  addTearDown(() async {
    // Built files are read-only, and `cp -R` keeps that.
    await Process.run('chmod', ['-R', 'u+w', out.path]);
    out.deleteSync(recursive: true);
  });
  var unpacked = 0;
  final built = (files.stdout as String).split('\n').where((l) => l.isNotEmpty);
  for (final file in built) {
    final path = p.join(_workspace, file);
    final into = p.join(out.path, '${unpacked++}');
    if (RegExp(r'(?<!_unsigned)\.(zip|ipa|apk)$').hasMatch(file)) {
      await Process.run('unzip', ['-q', path, '-d', into]);
    } else if (Directory(path).existsSync()) {
      await Process.run('cp', ['-RL', path, into]);
    }
  }
  for (final f in out.listSync(recursive: true)) {
    if (f is File && p.basename(f.path) == 'flutter_sdk.json') {
      return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    }
  }
  return null;
}

/// The names of the out dirs [record] says its engine pieces came from.
Set<Object?> _outDirs(Map<String, Object?> record) =>
    (record['engine'] as Map).values.map((e) => (e as Map)['out_dir']).toSet();

/// What every record must be: the checkout's, with no path of this machine.
void _expectRecordOfTheCheckout(Map<String, Object?> record) {
  expect(record['sdk'], 'local');
  expect(record['snapshot_hash'], _snapshotHash);
  expect(record['framework'], containsPair('origin', 'local'));
  expect(
    jsonEncode(record),
    isNot(contains(Directory.current.parent.path)),
    reason: 'no machine path in the record',
  );
  expect(
    jsonEncode(record).contains('"/'),
    isFalse,
    reason: 'no absolute path in the record',
  );
}

/// The iOS device platform: the framework is built outside an application's
/// own platform transition here, so the platform is named.
const _iosDevice = '--platforms=@rules_flutter//flutter/platforms:ios_arm64';

const _allAbis =
    '--@rules_android//flags:android_platforms='
    '@rules_android//:armeabi-v7a,@rules_android//:arm64-v8a,@rules_android//:x86_64';

String _abiFlag(String abi) =>
    '--@rules_android//flags:android_platforms=@rules_android//:$abi';

void main() {
  for (final mode in [
    ['release', <String>[]],
    [
      'debug',
      ['-c', 'dbg'],
    ],
  ]) {
    test('the ${mode[0]} app records the checkout it was built from', () async {
      final record = (await _record('local', mode[1] as List<String>))!;
      _expectRecordOfTheCheckout(record);
      expect(_outDirs(record), contains('host_${mode[0]}_arm64'));
    });
  }

  test('the iOS simulator app records the simulator out dir', () async {
    final record = (await _record(
      'local',
      const ['-c', 'dbg'],
      target: '//:ios_simulator',
    ))!;
    _expectRecordOfTheCheckout(record);
    expect(
      _outDirs(record),
      containsAll(['ios_debug_sim_arm64', 'host_debug_arm64']),
    );
  });

  test('the iOS device framework records the release out dir', () async {
    final record = (await _record(
      'local',
      const [_iosDevice],
      target: '//:ios_device_framework',
    ))!;
    _expectRecordOfTheCheckout(record);
    expect(
      _outDirs(record),
      containsAll(['ios_release', 'host_release_arm64']),
    );
  });

  for (final abi in [
    ['arm64-v8a', 'arm64'],
    ['x86_64', 'x64'],
    ['armeabi-v7a', ''],
  ]) {
    test('the ${abi[0]} APK records the ${abi[1]} out dir', () async {
      final record = (await _record(
        'local',
        [_abiFlag(abi[0])],
        target: '//:android_app',
      ))!;
      _expectRecordOfTheCheckout(record);
      expect(
        _outDirs(record),
        contains('android_release${abi[1].isEmpty ? '' : '_${abi[1]}'}'),
      );
    });
  }

  test('the debug APK is built from the debug out dir', () async {
    final record = (await _record(
      'local',
      const ['-c', 'dbg'],
      target: '//:android_app',
    ))!;
    _expectRecordOfTheCheckout(record);
    expect(_outDirs(record), contains('android_debug_arm64'));
  });

  test('an APK for every ABI carries the engine of each', () async {
    const flags = [_allAbis];
    final build = await _bazel([
      'build',
      '//:android_app',
      '${_sdkFlag}local',
      ...flags,
    ]);
    expect(build.exitCode, 0, reason: '${build.stderr}');
    final files = await _bazel([
      'cquery',
      '//:android_app',
      '${_sdkFlag}local',
      ...flags,
      '--output=files',
    ]);
    final apk = (files.stdout as String)
        .split('\n')
        .firstWhere((l) => RegExp(r'(?<!_unsigned)\.apk$').hasMatch(l));
    final listing = await Process.run('unzip', [
      '-Z1',
      p.join(_workspace, apk),
    ]);
    final entries = '${listing.stdout}'.split('\n');
    for (final abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']) {
      expect(entries, contains('lib/$abi/libflutter.so'));
      expect(entries, contains('lib/$abi/libapp.so'));
    }
  });

  test('the program is told what the selected SDK is', () async {
    Future<String> kernelDefines(String sdk) async {
      final aquery = await _bazel([
        'aquery',
        'mnemonic(".*Kernel.*", //:app_flutter)',
        '$_sdkFlag$sdk',
        '--output=text',
      ]);
      expect(aquery.exitCode, 0, reason: '${aquery.stderr}');
      return RegExp(
        r'FLUTTER_[A-Z_]+=[^ ,\x27"]*',
      ).allMatches('${aquery.stdout}').map((m) => m.group(0)).toSet().join(' ');
    }

    // The release's framework revision is versions.bzl's; the stand-in
    // checkout is not a git repository, so it has none to report.
    expect(
      await kernelDefines('local'),
      allOf(
        matches(RegExp(r'FLUTTER_FRAMEWORK_REVISION=( |$)')),
        contains('FLUTTER_ENGINE_REVISION=89c39edfdf'),
      ),
    );
    expect(
      await kernelDefines('flutter'),
      isNot(matches(RegExp(r'FLUTTER_FRAMEWORK_REVISION=( |$)'))),
    );
  });

  test('the release SDK records nothing', () async {
    expect(await _record('flutter', const []), isNull);
    expect(
      await _record('flutter', const ['-c', 'dbg'], target: '//:ios_simulator'),
      isNull,
    );
    expect(
      await _record('flutter', const [], target: '//:android_app'),
      isNull,
    );
  });

  test('a gen_snapshot of another Dart is refused', () async {
    final build = await _bazel(['build', '//:app', '${_sdkFlag}mismatched']);
    expect(build.exitCode, isNot(0));
    final err = '${build.stderr}';
    expect(err, contains('does not match itself for release'));
    expect(err, contains('gen_snapshot'));
    expect(err, contains('snapshot hash $_snapshotHash'));
  });

  for (final target in [
    ['//:ios_device_framework', 'iOS device framework'],
    ['//:android_app', 'Android APK'],
  ]) {
    test(
      'a gen_snapshot of another Dart is refused for the ${target[1]}',
      () async {
        final build = await _bazel([
          'build',
          target[0],
          '${_sdkFlag}mismatched',
        ]);
        expect(build.exitCode, isNot(0));
        final err = '${build.stderr}';
        expect(err, contains('does not match itself for release'));
        expect(err, contains('gen_snapshot'));
        expect(err, contains('snapshot hash $_snapshotHash'));
      },
    );
  }

  test(
    'an unset checkout loads, and a build that selects it says what to set',
    () async {
      final query = await _bazel([
        'query',
        'deps(//:app)',
        '--output=label_kind',
      ]);
      expect(query.exitCode, 0, reason: '${query.stderr}');
      final build = await _bazel(['build', '//:app', '${_sdkFlag}env']);
      expect(build.exitCode, isNot(0));
      expect('${build.stderr}', contains('FLUTTER_CHECKOUT is not set'));
    },
  );
}
