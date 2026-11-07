/// An app built against a framework and an engine that are not the release's.
///
/// **The properties** (`e2e/custom_engine`, whose checkout is the official
/// artifacts laid out as a flutter/flutter checkout with engine out dirs):
///
///  1. Built with the SDK that names the checkout, in release and in debug, the
///     app carries `flutter_assets/flutter_sdk.json`: the out dirs and the
///     checkout it came from, the snapshot hash and the kernel format, and no
///     path of the machine that built it.
///  2. The release's apps carry no such file.
///  3. A gen_snapshot of another Dart than the engine's fails the build, naming
///     both and their hashes.
///  4. A checkout given by `--repo_env=FLUTTER_CHECKOUT` works; not set, the
///     repositories still load (`bazel query`) and a build that selects the SDK
///     says what to set.
@Tags(['e2e'])
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

/// The built app's `flutter_sdk.json`, or null when it has none.
Future<Map<String, Object?>?> _record(String sdk, List<String> extra) async {
  final build = await _bazel(['build', '//:app', '$_sdkFlag$sdk', ...extra]);
  expect(build.exitCode, 0, reason: '${build.stderr}');
  final files = await _bazel([
    'cquery',
    '//:app',
    '$_sdkFlag$sdk',
    ...extra,
    '--output=files',
  ]);
  final zip = (files.stdout as String)
      .split('\n')
      .firstWhere((l) => l.endsWith('.zip'));
  final out = Directory.systemTemp.createTempSync('custom_engine');
  addTearDown(() => out.deleteSync(recursive: true));
  await Process.run('unzip', ['-q', p.join(_workspace, zip), '-d', out.path]);
  for (final f in out.listSync(recursive: true)) {
    if (f is File && p.basename(f.path) == 'flutter_sdk.json') {
      return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    }
  }
  return null;
}

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
      expect(record['sdk'], 'local');
      expect(record['snapshot_hash'], _snapshotHash);
      expect(record['framework'], containsPair('origin', 'local'));
      final engine = record['engine'] as Map;
      expect(
        engine.values.map((e) => (e as Map)['out_dir']),
        contains('host_${mode[0]}_arm64'),
      );
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
    });
  }

  test('the release SDK records nothing', () async {
    expect(await _record('flutter', const []), isNull);
  });

  test('a gen_snapshot of another Dart is refused', () async {
    final build = await _bazel(['build', '//:app', '${_sdkFlag}mismatched']);
    expect(build.exitCode, isNot(0));
    final err = '${build.stderr}';
    expect(err, contains('does not match itself for release'));
    expect(err, contains('gen_snapshot'));
    expect(err, contains('snapshot hash $_snapshotHash'));
  });

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
