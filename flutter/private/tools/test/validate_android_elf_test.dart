import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../validate_android_elf.dart';

/// A little-endian ELF64 file for [machine] whose one `PT_LOAD` segment is
/// aligned to [align].
List<int> elf64(int machine, {required int align}) {
  final data = ByteData(64 + 0x38);
  data.setUint32(0, 0x464c457f, Endian.little); // \x7fELF
  data.setUint8(4, 2); // ELFCLASS64
  data.setUint8(5, 1); // little-endian
  data.setUint16(18, machine, Endian.little);
  data.setUint64(0x20, 64, Endian.little); // e_phoff
  data.setUint16(0x36, 0x38, Endian.little); // e_phentsize
  data.setUint16(0x38, 1, Endian.little); // e_phnum
  data.setUint32(64, 1, Endian.little); // PT_LOAD
  data.setUint64(64 + 0x30, align, Endian.little);
  return data.buffer.asUint8List();
}

/// A zip archive of [entries], each stored ([deflate] false) or deflated.
List<int> zip(Map<String, List<int>> entries, {bool deflate = true}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final MapEntry(key: name, value: content) in entries.entries) {
    final body = deflate ? ZLibEncoder(raw: true).convert(content) : content;
    final offset = out.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(8, deflate ? 8 : 0, Endian.little)
      ..setUint32(18, body.length, Endian.little)
      ..setUint32(22, content.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name.codeUnits)
      ..add(body);
    final header = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(10, deflate ? 8 : 0, Endian.little)
      ..setUint32(20, body.length, Endian.little)
      ..setUint32(24, content.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(name.codeUnits);
  }
  final directory = out.length;
  final size = central.length;
  out.add(central.takeBytes());
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, size, Endian.little)
    ..setUint32(16, directory, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

/// The first bytes of an ELF file for [machine].
List<int> elfHeader(int machine) => [
  0x7f,
  0x45,
  0x4c,
  0x46,
  ...List.filled(14, 0),
  machine & 0xff,
  machine >> 8,
];

void main() {
  const arm64 = 183;
  const x86 = 62;

  group('elfProblem', () {
    String? problem(List<int> header, {int want = arm64}) => elfProblem(
      bytes: header,
      path: 'libfoo.so',
      abi: 'arm64-v8a',
      wantMachine: want,
    );

    test('accepts an ELF file of the ABI', () {
      expect(problem(elfHeader(arm64)), isNull);
      expect(problem(elfHeader(x86), want: x86), isNull);
    });

    test('refuses another architecture, naming both', () {
      expect(
        problem(elfHeader(x86)),
        'ERROR: libfoo.so has ELF machine 62; arm64-v8a requires 183.',
      );
    });

    test('refuses a Mach-O library', () {
      expect(
        problem([0xcf, 0xfa, 0xed, 0xfe, ...List.filled(16, 0)]),
        'ERROR: libfoo.so is not an ELF binary. Android (arm64-v8a) cannot '
        'load it.',
      );
    });

    test('refuses a file shorter than the header', () {
      expect(problem(elfHeader(arm64).sublist(0, 19)), contains('not an ELF'));
      expect(problem([]), contains('not an ELF'));
    });
  });

  group('16 KB pages', () {
    String? problem(List<int> bytes) => elfProblem(
      bytes: bytes,
      path: 'libfoo.so',
      abi: 'arm64-v8a',
      wantMachine: arm64,
      minLoadAlign: 16384,
    );

    test('accepts a library aligned to 16 KB or more', () {
      expect(problem(elf64(arm64, align: 16384)), isNull);
      expect(problem(elf64(arm64, align: 65536)), isNull);
    });

    test('refuses a library linked for 4 KB pages, naming the fix', () {
      final message = problem(elf64(arm64, align: 4096))!;
      expect(message, startsWith('ERROR: libfoo.so is linked for 4 KB pages'));
      expect(message, contains('-Wl,-z,max-page-size=16384'));
      expect(message, contains("plugin's AAR"));
      expect(message, contains('pin rules_android_ndk to a commit'));
    });

    test('is not checked without a minimum', () {
      expect(
        elfProblem(
          bytes: elf64(arm64, align: 4096),
          path: 'libfoo.so',
          abi: 'armeabi-v7a',
          wantMachine: arm64,
        ),
        isNull,
      );
    });
  });

  group('zipLibraries', () {
    for (final deflate in [true, false]) {
      test('reads the .so entries ${deflate ? 'deflated' : 'stored'}', () {
        final library = elf64(arm64, align: 4096);
        final libraries = zipLibraries(
          Uint8List.fromList(
            zip({
              'lib/arm64-v8a/libfoo.so': library,
              'AndroidManifest.xml': [1, 2, 3],
            }, deflate: deflate),
          ),
        );
        expect(libraries.keys, ['lib/arm64-v8a/libfoo.so']);
        expect(libraries.values.single, library);
      });
    }
  });

  group('run', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('validate_elf'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(String name, List<int> bytes) {
      final path = '${dir.path}/$name';
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    test('stamps when every library is valid', () {
      final stamp = '${dir.path}/stamp';
      final code = run([
        '--abi',
        'arm64-v8a',
        '--machine',
        '$arm64',
        '--stamp',
        stamp,
        write('liba.so', elfHeader(arm64)),
        write('libb.so', elfHeader(arm64)),
      ]);
      expect(code, 0);
      expect(File(stamp).readAsStringSync(), 'arm64-v8a\n');
    });

    test('checks the libraries inside a zip, naming the entry', () {
      final stamp = '${dir.path}/stamp';
      final archive = write(
        'native_libs.zip',
        zip({'jni/arm64-v8a/libbar.so': elf64(arm64, align: 4096)}),
      );
      final code = run([
        '--abi',
        'arm64-v8a',
        '--machine',
        '$arm64',
        '--min-load-align',
        '16384',
        '--stamp',
        stamp,
        write('libfoo.so', elf64(arm64, align: 16384)),
        archive,
      ]);
      expect(code, 1);
      expect(File(stamp).existsSync(), isFalse);
    });

    test('fails and writes no stamp when one library is wrong', () {
      final stamp = '${dir.path}/stamp';
      final code = run([
        '--abi',
        'arm64-v8a',
        '--machine',
        '$arm64',
        '--stamp',
        stamp,
        write('liba.so', elfHeader(arm64)),
        write('libb.so', elfHeader(x86)),
      ]);
      expect(code, 1);
      expect(File(stamp).existsSync(), isFalse);
    });
  });
}
