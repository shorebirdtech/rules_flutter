import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/bytes.dart';
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

    group('checkRunnerResources', () {
      // An icon of two images, as `.ico` lays them out: a header, a 16-byte
      // directory entry per image (its size at +8, its offset at +12), then
      // the images.
      final images = [
        [1, 2, 3, 4, 5],
        [6, 7, 8],
      ];
      List<int> u16(int v) => [v & 0xff, v >> 8];
      List<int> u32(int v) => [...u16(v & 0xffff), ...u16(v >> 16)];
      final ico = <int>[
        ...u16(0),
        ...u16(1),
        ...u16(2),
        ...[0, 0, 0, 0, 0, 0, 0, 0],
        ...u32(5),
        ...u32(38),
        ...[0, 0, 0, 0, 0, 0, 0, 0],
        ...u32(3),
        ...u32(43),
        ...images[0],
        ...images[1],
      ];
      final fixedFileInfo = [
        ...u32(0xFEEF04BD),
        ...u32(0x00010000),
        ...u32(2 << 16 | 3),
        ...u32(4 << 16 | 56),
      ];
      final manifest = utf8.encode(
        '<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/'
        'WindowsSettings">PerMonitorV2</dpiAwareness>',
      );

      WindowsBundle bundle(List<int> exe) {
        File('${tmp.path}/b/b.exe')
          ..createSync(recursive: true)
          ..writeAsBytesSync(exe);
        File('${tmp.path}/app_icon.ico').writeAsBytesSync(ico);
        return WindowsBundle('${tmp.path}/b', check: check);
      }

      void runCheck(WindowsBundle b) => b.checkRunnerResources(
        version: '2.3.4+56',
        fileVersion: [2, 3, 4, 56],
        icon: '${tmp.path}/app_icon.ico',
      );

      test('reads the images out of an icon file', () {
        expect(iconImages(ico), images);
      });

      test('accepts a runner that carries every resource', () {
        runCheck(
          bundle([
            0,
            ...fixedFileInfo,
            0,
            ...utf16leBytes('FileVersion'),
            0,
            ...utf16leBytes('2.3.4+56'),
            0,
            ...manifest,
            0,
            ...images[1],
            0,
            ...images[0],
          ]),
        );
        expect(check.failures, isEmpty);
      });

      test('names each resource a runner lacks', () {
        runCheck(bundle([...fixedFileInfo.sublist(0, 8), ...images[0]]));
        expect(check.failures, [
          startsWith('Version information, file version 2.3.4.56'),
          startsWith('Version string 2.3.4+56'),
          startsWith('Embedded manifest'),
          startsWith('Icon (2 images of app_icon.ico)'),
        ]);
      });
    });
  });
}
