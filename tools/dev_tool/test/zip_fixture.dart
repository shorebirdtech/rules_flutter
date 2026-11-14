/// Zip archives built in process, for tests whose subject is reading one.
///
/// A test that builds its fixture with the host's `zip` depends on the host
/// having one: macOS and GitHub's Ubuntu image do, a plain Ubuntu cloud image
/// ships only `unzip`, and Windows has neither. The format needed here is small
/// enough to write directly: stored or deflated entries, a central directory,
/// no extras, no encryption, no zip64.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The bytes of a zip archive holding [entries] (entry name to content), each
/// deflated when [deflate] is set and stored otherwise.
Uint8List zipBytes(Map<String, List<int>> entries, {bool deflate = false}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final MapEntry(key: name, value: data) in entries.entries) {
    final nameBytes = utf8.encode(name);
    final compressed = deflate
        ? ZLibCodec(raw: true, level: 9).encode(data)
        : data;
    final offset = out.length;
    final crc = _crc32(data);

    out
      ..add(_u32(0x04034b50))
      ..add(_u16(20)) // version needed
      ..add(_u16(0)) // flags
      ..add(_u16(deflate ? 8 : 0)) // method
      ..add(_u16(0)) // time
      ..add(_u16(0x21)) // date: 1980-01-01
      ..add(_u32(crc))
      ..add(_u32(compressed.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0)) // extra length
      ..add(nameBytes)
      ..add(compressed);

    central
      ..add(_u32(0x02014b50))
      ..add(_u16(20)) // version made by
      ..add(_u16(20)) // version needed
      ..add(_u16(0))
      ..add(_u16(deflate ? 8 : 0))
      ..add(_u16(0))
      ..add(_u16(0x21))
      ..add(_u32(crc))
      ..add(_u32(compressed.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0)) // extra length
      ..add(_u16(0)) // comment length
      ..add(_u16(0)) // disk
      ..add(_u16(0)) // internal attributes
      ..add(_u32(0)) // external attributes
      ..add(_u32(offset))
      ..add(nameBytes);
    count++;
  }
  final centralOffset = out.length;
  final centralBytes = central.takeBytes();
  out
    ..add(centralBytes)
    ..add(_u32(0x06054b50))
    ..add(_u16(0)) // this disk
    ..add(_u16(0)) // disk with the central directory
    ..add(_u16(count))
    ..add(_u16(count))
    ..add(_u32(centralBytes.length))
    ..add(_u32(centralOffset))
    ..add(_u16(0)); // comment length
  return out.takeBytes();
}

/// Write the files under each of [include] (paths relative to [base], files or
/// directories) into a zip at [zipPath], named relative to [base] with `/`.
void zipTree({
  required String zipPath,
  required String base,
  required List<String> include,
  bool deflate = false,
}) {
  final entries = <String, List<int>>{};
  for (final name in include) {
    final path = '$base/$name';
    if (FileSystemEntity.isDirectorySync(path)) {
      for (final file in Directory(path).listSync(recursive: true)) {
        if (file is! File) continue;
        entries[_relative(base, file.path)] = file.readAsBytesSync();
      }
    } else {
      entries[name] = File(path).readAsBytesSync();
    }
  }
  File(zipPath).writeAsBytesSync(zipBytes(entries, deflate: deflate));
}

String _relative(String base, String path) =>
    path.substring(base.length + 1).replaceAll(r'\', '/');

Uint8List _u16(int v) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
