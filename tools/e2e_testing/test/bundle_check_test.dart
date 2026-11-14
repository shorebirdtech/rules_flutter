import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StringBuffer out;
  late StringBuffer err;
  late List<int> exits;
  late BundleCheck check;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('e2e_testing_test');
    out = StringBuffer();
    err = StringBuffer();
    exits = [];
    check = BundleCheck(out: out, err: err, exit: exits.add);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String relative, [String contents = 'x']) =>
      File('${tmp.path}/$relative')
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);

  group('BundleCheck', () {
    test('exists passes for a file and a directory', () {
      write('a/file');
      check
        ..exists('file', '${tmp.path}/a/file')
        ..exists('dir', '${tmp.path}/a');
      expect(check.ok, isTrue);
      expect(out.toString(), contains('OK: file (1 bytes)'));
      expect(out.toString(), contains('OK: dir\n'));
    });

    test(
      'exists fails for a missing path and, with nonEmpty, an empty file',
      () {
        write('empty', '');
        check
          ..exists('missing', '${tmp.path}/nope')
          ..exists('empty', '${tmp.path}/empty')
          ..exists('empty is fine', '${tmp.path}/empty', nonEmpty: false)
          ..exists('empty is not', '${tmp.path}/empty', nonEmpty: true);
        expect(check.failures, hasLength(2));
        expect(err.toString(), contains('FAIL: missing — not found'));
        expect(err.toString(), contains('FAIL: empty is not — file is empty'));
      },
    );

    test('absent fails when something is there', () {
      write('there');
      check
        ..absent('gone', '${tmp.path}/gone')
        ..absent('there', '${tmp.path}/there');
      expect(check.failures, ['there is present: ${tmp.path}/there']);
    });

    test('command validates the trimmed output and the exit code', () {
      check
        ..command('echoes', 'echo', ['hi'], (s) => s == 'hi')
        ..command('wrong output', 'echo', ['hi'], (s) => s == 'no')
        ..command('fails', 'false', const [], (_) => true);
      expect(check.failures, hasLength(2));
      expect(err.toString(), contains('wrong output — unexpected output: hi'));
      expect(err.toString(), contains('fails — command failed: false'));
    });

    test('finish prints success, or lists the tree and exits 1', () {
      write('d/f', 'abc');
      check.finish('done');
      expect(out.toString(), 'done\n');
      expect(exits, isEmpty);

      check.fail('bad');
      check.finish('done', onFailure: () => check.listTree(tmp));
      expect(exits, [1]);
      expect(err.toString(), contains('d/\n  f (3 bytes)'));
    });

    test('listTree stops at directories descend refuses', () {
      write('x.framework/inner');
      write('plain/inner');
      check.listTree(tmp, descend: (d) => !d.path.endsWith('.framework'));
      expect(err.toString(), contains('x.framework/\n'));
      expect(err.toString(), isNot(contains('x.framework/\n  inner')));
      expect(err.toString(), contains('plain/\n  inner'));
    });
  });
}
