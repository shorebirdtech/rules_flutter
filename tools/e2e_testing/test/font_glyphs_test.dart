import 'dart:typed_data';

import 'package:rules_flutter_e2e_testing/font_glyphs.dart';
import 'package:test/test.dart';

/// An sfnt file holding only a `cmap` table with the given Unicode sub-tables.
Uint8List sfnt(List<Uint8List> subtables) {
  final header = 4 + 8 * subtables.length;
  final cmap = BytesBuilder()..add([0, 0, 0, subtables.length]);
  var offset = header;
  for (final table in subtables) {
    cmap.add([0, 3, 0, table[0] == 0 && table[1] == 12 ? 10 : 1]);
    cmap.add(
      (ByteData(4)..setUint32(0, offset)).buffer.asUint8List(),
    );
    offset += table.length;
  }
  subtables.forEach(cmap.add);
  final cmapBytes = cmap.toBytes();

  final file = ByteData(12 + 16 + cmapBytes.length);
  file.setUint32(0, 0x4F54544F); // 'OTTO'
  file.setUint16(4, 1);
  for (var i = 0; i < 4; i++) {
    file.setUint8(12 + i, 'cmap'.codeUnitAt(i));
  }
  file.setUint32(12 + 8, 12 + 16);
  file.setUint32(12 + 12, cmapBytes.length);
  final bytes = file.buffer.asUint8List()..setAll(12 + 16, cmapBytes);
  return bytes;
}

Uint8List format4(List<({int start, int end, int delta})> segments) {
  // One extra segment ends the table at 0xFFFF, as the format requires.
  final all = [...segments, (start: 0xFFFF, end: 0xFFFF, delta: 1)];
  final n = all.length;
  final data = ByteData(16 + 8 * n)
    ..setUint16(0, 4)
    ..setUint16(2, 16 + 8 * n)
    ..setUint16(6, 2 * n);
  for (var i = 0; i < n; i++) {
    data
      ..setUint16(14 + 2 * i, all[i].end)
      ..setUint16(14 + 2 * n + 2 + 2 * i, all[i].start)
      ..setUint16(14 + 4 * n + 2 + 2 * i, all[i].delta);
  }
  return data.buffer.asUint8List();
}

Uint8List format12(List<({int start, int end, int glyph})> groups) {
  final data = ByteData(16 + 12 * groups.length)
    ..setUint16(0, 12)
    ..setUint32(12, groups.length);
  for (var i = 0; i < groups.length; i++) {
    data
      ..setUint32(16 + 12 * i, groups[i].start)
      ..setUint32(16 + 12 * i + 4, groups[i].end)
      ..setUint32(16 + 12 * i + 8, groups[i].glyph);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('a format 4 table lists the characters of its segments', () {
    final font = sfnt([
      format4([
        (start: 0xe037, end: 0xe037, delta: 0x10000 - 0xe037 + 3),
        (start: 0xe318, end: 0xe31a, delta: 0x10000 - 0xe318 + 4),
      ]),
    ]);
    expect(fontCodePoints(font), {0xe037, 0xe318, 0xe319, 0xe31a});
  });

  test('a format 12 table reaches beyond the Basic Multilingual Plane', () {
    final font = sfnt([
      format12([
        (start: 0xe318, end: 0xe318, glyph: 7),
        (start: 0xf055d, end: 0xf055e, glyph: 8),
      ]),
    ]);
    expect(fontCodePoints(font), {0xe318, 0xf055d, 0xf055e});
  });

  test('a character mapped to glyph 0 is not in the font', () {
    final font = sfnt([
      format12([
        (start: 0xe001, end: 0xe001, glyph: 0),
        (start: 0xe002, end: 0xe002, glyph: 5),
      ]),
    ]);
    expect(fontCodePoints(font), {0xe002});
  });

  test('a file that is not an sfnt font is refused', () {
    expect(() => fontCodePoints([1, 2, 3]), throwsFormatException);
    expect(
      () => fontCodePoints(Uint8List(64)),
      throwsFormatException,
      reason: 'no cmap table',
    );
  });
}
