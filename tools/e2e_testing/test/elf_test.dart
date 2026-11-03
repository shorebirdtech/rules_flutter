import 'dart:typed_data';

import 'package:rules_flutter_e2e_testing/elf.dart';
import 'package:test/test.dart';

/// A minimal ELF64 little-endian image: a header, then one program header per
/// entry of [alignments] (all `PT_LOAD`).
Uint8List elf64({int machine = 0xb7, List<int> alignments = const []}) {
  const phoff = 64;
  const phentsize = 56;
  final bytes = Uint8List(phoff + alignments.length * phentsize);
  final data = ByteData.sublistView(bytes)
    ..setUint16(18, machine, Endian.little)
    ..setUint64(0x20, phoff, Endian.little)
    ..setUint16(0x36, phentsize, Endian.little)
    ..setUint16(0x38, alignments.length, Endian.little);
  bytes.setRange(0, 4, [0x7f, 0x45, 0x4c, 0x46]);
  bytes[4] = 2;
  for (var i = 0; i < alignments.length; i++) {
    final off = phoff + i * phentsize;
    data
      ..setUint32(off, 1, Endian.little)
      ..setUint64(off + 0x30, alignments[i], Endian.little);
  }
  return bytes;
}

/// An ELF64 image with section headers named [names], between a null section
/// and a string table section.
Uint8List elf64WithSections(List<String> names) {
  final strtab = <int>[0];
  final nameOffsets = <int>[0];
  for (final name in names) {
    nameOffsets.add(strtab.length);
    strtab
      ..addAll(name.codeUnits)
      ..add(0);
  }
  const shentsize = 64;
  final shnum = names.length + 2;
  // Section headers follow the 64-byte header; the string table follows them.
  final strtabOffset = 64 + shnum * shentsize;
  final bytes = Uint8List(strtabOffset + strtab.length);
  final data = ByteData.sublistView(bytes)
    ..setUint64(0x28, 64, Endian.little)
    ..setUint16(0x3a, shentsize, Endian.little)
    ..setUint16(0x3c, shnum, Endian.little)
    // The string table is the last section header.
    ..setUint16(0x3e, shnum - 1, Endian.little);
  for (var i = 0; i < shnum - 1; i++) {
    data.setUint32(64 + i * shentsize, nameOffsets[i], Endian.little);
  }
  data.setUint64(
    64 + (shnum - 1) * shentsize + 0x18,
    strtabOffset,
    Endian.little,
  );
  bytes.setRange(strtabOffset, strtabOffset + strtab.length, strtab);
  return bytes;
}

void main() {
  group('validate', () {
    test('accepts an ELF of the expected machine', () {
      expect(
        ElfImage(elf64()).validate(elfMachineForAbi['arm64-v8a']!),
        isNull,
      );
      expect(
        ElfImage(elf64(machine: 0x3e)).validate(elfMachineForAbi['x86_64']!),
        isNull,
      );
    });

    test('names the machine when it is the wrong one', () {
      expect(
        ElfImage(elf64(machine: 0x3e)).validate(0xb7),
        'ELF machine 0x3e does not match expected 0xb7',
      );
    });

    test('names a Mach-O file as the host format', () {
      final macho = Uint8List(32)..setRange(0, 4, [0xcf, 0xfa, 0xed, 0xfe]);
      expect(ElfImage(macho).validate(0xb7), contains('Mach-O'));
    });

    test('rejects other magic and truncated files', () {
      expect(ElfImage(Uint8List(32)).validate(0xb7), contains('not an ELF'));
      expect(ElfImage(Uint8List(8)).validate(0xb7), contains('too small'));
    });
  });

  group('minLoadAlignment', () {
    test('is the smallest PT_LOAD alignment', () {
      expect(
        ElfImage(elf64(alignments: [0x4000, 0x1000, 0x4000]))
            .minLoadAlignment(),
        (0x1000, null),
      );
      expect(
        ElfImage(elf64(alignments: [0x4000, 0x10000])).minLoadAlignment(),
        (0x4000, null),
      );
    });

    test('reports an ELF with no PT_LOAD segment', () {
      final (align, error) = ElfImage(elf64()).minLoadAlignment();
      expect(align, isNull);
      expect(error, contains('no PT_LOAD'));
    });

    test('reports headers that run past the end of the file', () {
      final bytes = elf64(alignments: [0x4000]);
      final cut = Uint8List.sublistView(bytes, 0, bytes.length - 8);
      final (align, error) = ElfImage(cut).minLoadAlignment();
      expect(align, isNull);
      expect(error, contains('past the end'));
    });

    test('reports a file shorter than an ELF header', () {
      final (align, error) = ElfImage(Uint8List(10)).minLoadAlignment();
      expect(align, isNull);
      expect(error, contains('shorter than an ELF header'));
    });
  });

  group('sectionNames', () {
    test('lists the names, starting with the null section', () {
      expect(
        ElfImage(elf64WithSections(['.text', '.symtab', '.debug_info']))
            .sectionNames(),
        ['', '.text', '.symtab', '.debug_info', ''],
      );
    });

    test('is empty without section headers', () {
      expect(ElfImage(elf64()).sectionNames(), isEmpty);
      expect(ElfImage(Uint8List(8)).sectionNames(), isEmpty);
    });
  });
}
