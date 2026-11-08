import 'dart:convert';
import 'dart:typed_data';

import 'package:rules_flutter_e2e_testing/zip_entries.dart';
import 'package:test/test.dart';

List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];

List<int> _u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

/// What [zip] writes as an entry's CRC-32: not the real checksum, which
/// nothing here computes, but equal exactly for equal [content] in these tests.
int fakeCrc(List<int> content) =>
    content.fold(content.length, (h, b) => (h * 31 + b) & 0xffffffff);

/// A zip archive of [entries]: each a name, a compression method, the bytes
/// to store and the length of the local header's extra field, which is how
/// zipalign pads an entry's data to an alignment.
Uint8List zip(List<(String, int, List<int>, int)> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final (name, method, content, extra) in entries) {
    final offset = out.length;
    final encoded = utf8.encode(name);
    out
      ..add(_u32(0x04034b50))
      ..add(_u16(20)) // version needed
      ..add(_u16(0)) // flags
      ..add(_u16(method))
      ..add(_u32(0)) // time, date
      ..add(_u32(0)) // crc
      ..add(_u32(content.length))
      ..add(_u32(content.length))
      ..add(_u16(encoded.length))
      ..add(_u16(extra))
      ..add(encoded)
      ..add(List.filled(extra, 0))
      ..add(content);
    central
      ..add(_u32(0x02014b50))
      ..add(_u16(20)) // version made by
      ..add(_u16(20)) // version needed
      ..add(_u16(0))
      ..add(_u16(method))
      ..add(_u32(0)) // time, date
      ..add(_u32(fakeCrc(content)))
      ..add(_u32(content.length))
      ..add(_u32(content.length))
      ..add(_u16(encoded.length))
      ..add(_u16(0)) // extra
      ..add(_u16(0)) // comment
      ..add(_u16(0)) // disk
      ..add(_u16(0)) // internal attributes
      ..add(_u32(0)) // external attributes
      ..add(_u32(offset))
      ..add(encoded);
  }
  final directory = out.length;
  final c = central.toBytes();
  out
    ..add(c)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(c.length))
    ..add(_u32(directory))
    ..add(_u16(0));
  return out.toBytes();
}

void main() {
  test('reads each entry with its method and where its data starts', () {
    final entries = zipEntries(
      zip([
        ('lib/arm64-v8a/libapp.so', 0, [1, 2, 3], 7),
        ('classes.dex', 8, [4, 5], 0),
      ]),
    );
    expect(entries.map((e) => e.name), [
      'lib/arm64-v8a/libapp.so',
      'classes.dex',
    ]);
    expect(entries.map((e) => e.stored), [true, false]);
    // 30-byte local header, then the name, then the extra field.
    expect(entries.first.dataOffset, 30 + 23 + 7);
    expect(entries.last.dataOffset, 30 + 23 + 7 + 3 + 30 + 11);
    expect(entries.last.crc32, fakeCrc([4, 5]));
  });

  test('rejects what is not a zip archive', () {
    expect(() => zipEntries(Uint8List(64)), throwsFormatException);
  });
}
