import 'dart:io';

import 'package:test/test.dart';

import '../validate_android_elf.dart';

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
      header: header,
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
