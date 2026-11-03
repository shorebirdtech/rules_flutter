/// Reading which characters a font has a glyph for.
library;

import 'dart:typed_data';

/// The code points [font] (the bytes of a TrueType or OpenType file) has a
/// glyph for, read from its `cmap` table.
///
/// A character mapped to glyph 0 (`.notdef`) counts as absent: that is what a
/// subsetter leaves for a character it dropped, and what a text engine draws
/// as a blank box. Handles the table formats fonts use for the Basic
/// Multilingual Plane (4) and for all of Unicode (12), in any of the font's
/// Unicode sub-tables.
///
/// Throws [FormatException] if [font] is not an sfnt font or has no Unicode
/// `cmap`.
Set<int> fontCodePoints(List<int> font) {
  final data = ByteData.sublistView(Uint8List.fromList(font));
  if (data.lengthInBytes < 12) {
    throw const FormatException('Too short to be an sfnt font');
  }
  final tableCount = data.getUint16(4);
  int? cmapOffset;
  for (var i = 0; i < tableCount; i++) {
    final record = 12 + 16 * i;
    final tag = String.fromCharCodes(
      Uint8List.sublistView(data, record, record + 4),
    );
    if (tag == 'cmap') cmapOffset = data.getUint32(record + 8);
  }
  if (cmapOffset == null) {
    throw const FormatException('The font has no cmap table');
  }

  final subtables = data.getUint16(cmapOffset + 2);
  final codePoints = <int>{};
  var sawUnicode = false;
  for (var i = 0; i < subtables; i++) {
    final record = cmapOffset + 4 + 8 * i;
    final platform = data.getUint16(record);
    final encoding = data.getUint16(record + 2);
    // Platform 0 is Unicode; platform 3 is Windows, whose encodings 1 and 10
    // are Unicode BMP and full Unicode.
    final unicode =
        platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
    if (!unicode) continue;
    sawUnicode = true;
    final offset = cmapOffset + data.getUint32(record + 4);
    switch (data.getUint16(offset)) {
      case 4:
        _readFormat4(data, offset, codePoints);
      case 12:
        _readFormat12(data, offset, codePoints);
      default:
      // Another format maps characters the two above also cover in every
      // font this reads.
    }
  }
  if (!sawUnicode) throw const FormatException('The font has no Unicode cmap');
  return codePoints;
}

void _readFormat4(ByteData data, int offset, Set<int> into) {
  final segments = data.getUint16(offset + 6) ~/ 2;
  final ends = offset + 14;
  final starts = ends + 2 * segments + 2;
  final deltas = starts + 2 * segments;
  final rangeOffsets = deltas + 2 * segments;
  for (var s = 0; s < segments; s++) {
    final end = data.getUint16(ends + 2 * s);
    final start = data.getUint16(starts + 2 * s);
    final delta = data.getUint16(deltas + 2 * s);
    final rangeOffset = data.getUint16(rangeOffsets + 2 * s);
    for (var c = start; c <= end && c != 0xFFFF; c++) {
      final int glyph;
      if (rangeOffset == 0) {
        glyph = (c + delta) & 0xFFFF;
      } else {
        final at = rangeOffsets + 2 * s + rangeOffset + 2 * (c - start);
        final raw = data.getUint16(at);
        glyph = raw == 0 ? 0 : (raw + delta) & 0xFFFF;
      }
      if (glyph != 0) into.add(c);
    }
  }
}

void _readFormat12(ByteData data, int offset, Set<int> into) {
  final groups = data.getUint32(offset + 12);
  for (var g = 0; g < groups; g++) {
    final group = offset + 16 + 12 * g;
    final start = data.getUint32(group);
    final end = data.getUint32(group + 4);
    final firstGlyph = data.getUint32(group + 8);
    for (var c = start; c <= end; c++) {
      if (firstGlyph + (c - start) != 0) into.add(c);
    }
  }
}
