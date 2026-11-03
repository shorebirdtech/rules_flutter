import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/desktop_bundle.dart';
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

  group('LinuxBundle', () {
    void fill(String name, {bool aot = true}) {
      for (final f in [
        name,
        'lib/libflutter_linux_gtk.so',
        'data/icudtl.dat',
      ]) {
        write('b/$f');
      }
      write(aot ? 'b/lib/libapp.so' : 'b/data/flutter_assets/kernel_blob.bin');
      for (final f in ['AssetManifest.bin', 'FontManifest.json', 'NOTICES.Z']) {
        write('b/data/flutter_assets/$f');
      }
    }

    test('accepts an AOT or a debug bundle', () {
      fill('b');
      LinuxBundle('${tmp.path}/b', check: check)..checkStandardLayout();
      expect(check.failures, isEmpty);
      expect(out.toString(), contains('OK: AOT snapshot'));

      tmp.deleteSync(recursive: true);
      tmp.createSync();
      fill('b', aot: false);
      check = BundleCheck(out: out, err: err, exit: exits.add);
      LinuxBundle('${tmp.path}/b', check: check)..checkStandardLayout();
      expect(check.failures, isEmpty);
      expect(out.toString(), contains('OK: Kernel blob (debug)'));
    });

    test('names what is missing', () {
      fill('b');
      File('${tmp.path}/b/lib/libapp.so').deleteSync();
      File('${tmp.path}/b/data/icudtl.dat').deleteSync();
      LinuxBundle('${tmp.path}/b', check: check).checkStandardLayout();
      expect(
        check.failures,
        contains(
          'Neither lib/libapp.so nor data/flutter_assets/kernel_blob.bin found',
        ),
      );
      expect(
        check.failures.where((f) => f.startsWith('icudtl.dat')),
        hasLength(1),
      );
    });
  });

  group('WindowsBundle', () {
    test('expects the exe, the engine DLL and app.so', () {
      for (final f in [
        'b.exe',
        'flutter_windows.dll',
        'data/icudtl.dat',
        'data/app.so',
        'data/flutter_assets/AssetManifest.bin',
        'data/flutter_assets/FontManifest.json',
        'data/flutter_assets/NOTICES.Z',
      ]) {
        write('b/$f');
      }
      WindowsBundle('${tmp.path}/b', check: check).checkStandardLayout();
      expect(check.failures, isEmpty);
    });
  });
}
