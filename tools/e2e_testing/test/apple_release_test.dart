// Checks of the release-binary checks, on real Mach-O binaries `clang` builds,
// so a check that passes everything, or fails everything, is caught here and
// not as a green or red e2e test.
import 'dart:io';

import 'package:rules_flutter_e2e_testing/apple_release.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String unstripped;
  late String dsym;

  void run(String tool, List<String> args) {
    final result = Process.runSync('xcrun', [tool, ...args]);
    expect(
      result.exitCode,
      0,
      reason: '$tool ${args.join(' ')}: ${result.stderr}',
    );
  }

  /// A BundleCheck that records instead of printing or exiting.
  BundleCheck recorder() => BundleCheck(
    out: StringBuffer(),
    err: StringBuffer(),
    exit: (_) {},
  );

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('apple_release_test');
    File('${tmp.path}/lib.c').writeAsStringSync('''
static int local_helper(int x) { return x * 2; }
int exported(int x) { return local_helper(x) + 1; }
''');
    unstripped = '${tmp.path}/unstripped.dylib';
    run('clang', ['-g', '-dynamiclib', '-o', unstripped, '${tmp.path}/lib.c']);
    dsym = '${tmp.path}/unstripped.dylib.dSYM';
    run('dsymutil', [unstripped, '-o', dsym]);
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('checkAppBinaryStripped', () {
    test('fails a binary with local symbols and debugging-map entries', () {
      final check = recorder();
      checkAppBinaryStripped(check, unstripped);
      expect(check.failures, hasLength(2), reason: '${check.failures}');
    });

    test('passes the same binary after strip -x -S', () {
      final stripped = '${tmp.path}/stripped.dylib';
      File(unstripped).copySync(stripped);
      run('strip', ['-x', '-S', stripped]);
      final check = recorder();
      checkAppBinaryStripped(check, stripped);
      expect(check.failures, isEmpty, reason: '${check.failures}');
    });
  });

  group('checkAppBinaryKeepsSymbols', () {
    test('passes a binary with local symbols', () {
      final check = recorder();
      checkAppBinaryKeepsSymbols(check, unstripped);
      expect(check.failures, isEmpty, reason: '${check.failures}');
    });

    test('fails the same binary after strip -x -S', () {
      final stripped = '${tmp.path}/stripped_keeps.dylib';
      File(unstripped).copySync(stripped);
      run('strip', ['-x', '-S', stripped]);
      final check = recorder();
      checkAppBinaryKeepsSymbols(check, stripped);
      expect(check.failures, hasLength(1), reason: '${check.failures}');
    });
  });

  group('checkAppInstallName', () {
    test('fails a dylib installed under its build path', () {
      final check = recorder();
      checkAppInstallName(check, unstripped);
      expect(check.failures, hasLength(1), reason: '${check.failures}');
    });

    test('passes a dylib installed under @rpath/App.framework/App', () {
      final rpathed = '${tmp.path}/rpathed.dylib';
      run('clang', [
        '-dynamiclib',
        '-install_name',
        '@rpath/App.framework/App',
        '-o',
        rpathed,
        '${tmp.path}/lib.c',
      ]);
      final check = recorder();
      checkAppInstallName(check, rpathed);
      expect(check.failures, isEmpty, reason: '${check.failures}');
    });
  });

  group('checkDsymMatches', () {
    test('passes the dSYM made from the binary, also once it is stripped', () {
      final stripped = '${tmp.path}/stripped_for_dsym.dylib';
      File(unstripped).copySync(stripped);
      run('strip', ['-x', '-S', stripped]);
      for (final binary in [unstripped, stripped]) {
        final check = recorder();
        checkDsymMatches(check, binary, [dsym]);
        expect(check.failures, isEmpty, reason: '$binary: ${check.failures}');
      }
    });

    test('fails when the build produced no dSYM', () {
      final check = recorder();
      checkDsymMatches(check, unstripped, const []);
      expect(check.failures, hasLength(1));
    });

    test('fails a dSYM of another binary', () {
      final other = '${tmp.path}/other.dylib';
      File('${tmp.path}/other.c')
          .writeAsStringSync('int other(void) { return 3; }');
      run('clang', ['-g', '-dynamiclib', '-o', other, '${tmp.path}/other.c']);
      final check = recorder();
      checkDsymMatches(check, other, [dsym]);
      expect(check.failures, hasLength(1));
    });
  });
}
