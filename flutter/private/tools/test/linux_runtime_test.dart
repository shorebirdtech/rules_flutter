import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../linux_runtime.dart';

/// A 64-bit little-endian ELF file with a dynamic section naming [soname] and
/// [needed], and a version-needs section asking each library for its versions.
Uint8List _elf({
  String? soname,
  List<String> needed = const [],
  Map<String, List<String>> versions = const {},
}) {
  // The string table.
  final strings = BytesBuilder()..addByte(0);
  final offsets = <String, int>{};
  int str(String s) => offsets.putIfAbsent(s, () {
    final at = strings.length;
    strings
      ..add(utf8.encode(s))
      ..addByte(0);
    return at;
  });

  final dynamic = BytesBuilder();
  void entry(int tag, int value) {
    final b = ByteData(16)
      ..setUint64(0, tag, Endian.little)
      ..setUint64(8, value, Endian.little);
    dynamic.add(b.buffer.asUint8List());
  }

  for (final n in needed) {
    entry(1, str(n));
  }
  if (soname != null) entry(14, str(soname));
  entry(0, 0);

  final verneed = BytesBuilder();
  final files = versions.entries.toList();
  for (var i = 0; i < files.length; i++) {
    final MapEntry(key: file, value: names) = files[i];
    final need = ByteData(16)
      ..setUint16(0, 1, Endian.little)
      ..setUint16(2, names.length, Endian.little)
      ..setUint32(4, str(file), Endian.little)
      ..setUint32(8, 16, Endian.little)
      ..setUint32(
        12,
        i == files.length - 1 ? 0 : 16 + 16 * names.length,
        Endian.little,
      );
    verneed.add(need.buffer.asUint8List());
    for (var j = 0; j < names.length; j++) {
      final aux = ByteData(16)
        ..setUint32(8, str(names[j]), Endian.little)
        ..setUint32(12, j == names.length - 1 ? 0 : 16, Endian.little);
      verneed.add(aux.buffer.asUint8List());
    }
  }

  const header = 64;
  final strBytes = strings.toBytes();
  final dynBytes = dynamic.toBytes();
  final verBytes = verneed.toBytes();
  final strAt = header;
  final dynAt = strAt + strBytes.length;
  final verAt = dynAt + dynBytes.length;
  final shAt = verAt + verBytes.length;
  final sections = [
    (0, 0, 0, 0), // the null section
    (3, strAt, strBytes.length, 0), // .dynstr
    (6, dynAt, dynBytes.length, 1), // .dynamic, its strings in section 1
    (0x6ffffffe, verAt, verBytes.length, 1), // .gnu.version_r
  ];
  final out = ByteData(shAt + 64 * sections.length);
  final bytes = out.buffer.asUint8List()
    ..setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1])
    ..setAll(strAt, strBytes)
    ..setAll(dynAt, dynBytes)
    ..setAll(verAt, verBytes);
  out
    ..setUint64(0x28, shAt, Endian.little)
    ..setUint16(0x3a, 64, Endian.little)
    ..setUint16(0x3c, sections.length, Endian.little);
  for (var i = 0; i < sections.length; i++) {
    final (type, offset, size, link) = sections[i];
    final at = shAt + 64 * i;
    out
      ..setUint32(at + 4, type, Endian.little)
      ..setUint64(at + 0x18, offset, Endian.little)
      ..setUint64(at + 0x20, size, Endian.little)
      ..setUint32(at + 0x28, link, Endian.little);
  }
  return bytes;
}

const _floor = {
  'GLIBC': '2.39',
  'GLIBCXX': '3.4.33',
  'CXXABI': '1.3.15',
  'GCC': '14.0.0',
};
const _host = {'libc.so.6', 'libstdc++.so.6', 'libgcc_s.so.1'};

void main() {
  group('readElfDynamicInfo', () {
    test('reads the soname, the libraries needed and the versions asked '
        'of each', () {
      final info = readElfDynamicInfo(
        _elf(
          soname: 'libgtk-3.so.0',
          needed: ['libglib-2.0.so.0', 'libc.so.6'],
          versions: {
            'libc.so.6': ['GLIBC_2.34', 'GLIBC_2.2.5'],
            'libgcc_s.so.1': ['GCC_3.0'],
          },
        ),
      );

      expect(info.soname, 'libgtk-3.so.0');
      expect(info.needed, ['libglib-2.0.so.0', 'libc.so.6']);
      expect(info.versionsNeeded, {
        'libc.so.6': ['GLIBC_2.34', 'GLIBC_2.2.5'],
        'libgcc_s.so.1': ['GCC_3.0'],
      });
    });

    test('refuses an ELF file that is not 64-bit little-endian', () {
      final bytes = _elf()..[4] = 1;
      expect(() => readElfDynamicInfo(bytes), throwsFormatException);
    });
  });

  group('elfProblems', () {
    List<String> problems(
      ElfDynamicInfo info, {
      Set<String> provided = const {},
    }) => elfProblems(
      'lib/x.so',
      info,
      floor: _floor,
      hostLibraries: _host,
      provided: provided,
    );

    test('are none for a file within the floor whose libraries are all '
        'there', () {
      expect(
        problems(
          const ElfDynamicInfo(
            soname: 'x.so',
            needed: ['libc.so.6', 'libX11.so.6'],
            versionsNeeded: {
              'libc.so.6': ['GLIBC_2.39', 'GLIBC_2.2.5'],
              'libstdc++.so.6': ['GLIBCXX_3.4.33', 'CXXABI_1.3.15'],
              'libgcc_s.so.1': ['GCC_3.3.1'],
              'libX11.so.6': ['WHATEVER_1'],
            },
          ),
          provided: {'libX11.so.6'},
        ),
        isEmpty,
      );
    });

    test('name a version of a host library newer than the floor', () {
      expect(
        problems(
          const ElfDynamicInfo(
            soname: null,
            needed: ['libc.so.6'],
            versionsNeeded: {
              'libc.so.6': ['GLIBC_2.41'],
            },
          ),
        ),
        [
          contains(
            'asks libc.so.6 for GLIBC_2.41, newer than the host floor GLIBC_2.39',
          ),
        ],
      );
    });

    test('name a version of a host library the floor does not know, which '
        'could not be judged', () {
      expect(
        problems(
          const ElfDynamicInfo(
            soname: null,
            needed: ['libc.so.6'],
            versionsNeeded: {
              'libc.so.6': ['GLIBC_PRIVATE'],
            },
          ),
        ),
        [contains('GLIBC_PRIVATE')],
      );
    });

    test('name a library the runtime does not have', () {
      expect(
        problems(
          const ElfDynamicInfo(
            soname: null,
            needed: ['libsystemd.so.0'],
            versionsNeeded: {},
          ),
        ),
        ['lib/x.so needs libsystemd.so.0, which the runtime does not have'],
      );
    });
  });

  group('check', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('linux_runtime'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(String name, List<int> bytes) =>
        (File('${dir.path}/$name')..writeAsBytesSync(bytes)).path;

    List<String> args(
      List<String> files, {
      List<String> providers = const [],
    }) => [
      'check',
      '--stamp',
      '${dir.path}/stamp',
      for (final MapEntry(:key, :value) in _floor.entries) ...[
        '--floor',
        '$key=$value',
      ],
      for (final l in _host) ...['--host-library', l],
      for (final pr in providers) ...['--provider', pr],
      ...files,
    ];

    test('writes the stamp when every file holds, finding a library by the '
        'name of its file and passing over files that are not ELF', () {
      final lib = write('libfoo.so.1', _elf(needed: ['libc.so.6']));
      final app = write(
        'app',
        _elf(
          needed: ['libfoo.so.1', 'libbar.so.2'],
          versions: {
            'libc.so.6': ['GLIBC_2.17'],
          },
        ),
      );
      final bar = write('libbar.so.2', _elf());
      final text = write('README', utf8.encode('not ELF'));

      expect(run(args([lib, app, text], providers: [bar])), 0);
      expect(File('${dir.path}/stamp').readAsStringSync(), contains('2 ELF'));
    });

    test('fails, writing no stamp, on a file past the floor', () {
      final lib = write(
        'libnew.so',
        _elf(
          versions: {
            'libc.so.6': ['GLIBC_2.41'],
          },
        ),
      );

      expect(run(args([lib])), 1);
      expect(File('${dir.path}/stamp').existsSync(), isFalse);
    });
  });

  group('patchXvfb', () {
    test('empties the one string /usr/bin, and nothing else', () {
      final before = Uint8List.fromList([
        ...ascii.encode('\x00/usr/share/X11/xkb\x00/usr/bin\x00/usr/binx\x00'),
      ]);
      final after = patchXvfb(before);

      final at = ascii.decode(before).indexOf('\x00/usr/bin\x00') + 1;
      for (var i = 0; i < before.length; i++) {
        expect(after[i], i == at ? 0 : before[i], reason: 'byte $i');
      }
    });

    test('refuses a server that holds the string other than once', () {
      expect(
        () => patchXvfb(Uint8List.fromList(ascii.encode('\x00/usr/lib\x00'))),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('0 times'),
          ),
        ),
      );
      expect(
        () => patchXvfb(
          Uint8List.fromList(ascii.encode('\x00/usr/bin\x00/usr/bin\x00')),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('2 times'),
          ),
        ),
      );
    });
  });
}
