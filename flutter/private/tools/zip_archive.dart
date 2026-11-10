/// Reading and writing zip archives (jars, AARs) with nothing but `dart:io`.
///
/// The build actions that use it run as plain scripts from the toolchain's
/// Dart, with no pub packages, so this is a small zip of its own: the subset
/// of the format jars and AARs use (stored and deflated entries, no zip64,
/// no encryption). Archives it writes are deterministic: entries in the order
/// given, every timestamp the same, as Bazel's own zip tools write them.
library;

import 'dart:io';
import 'dart:typed_data';

const _endOfCentralDirectory = 0x06054b50;
const _centralHeader = 0x02014b50;
const _localHeader = 0x04034b50;

/// 2010-01-01 00:00:00 in MS-DOS form, the timestamp Bazel's zipper and
/// singlejar give every entry.
const _dosTime = 0;
const _dosDate = ((2010 - 1980) << 9) | (1 << 5) | 1;

/// One file of an archive.
class ZipEntry {
  ZipEntry(this.name, this.bytes);

  /// The entry's path in the archive, `/`-separated.
  final String name;
  final List<int> bytes;
}

/// The file entries of the zip archive [bytes], in central directory order.
/// Directory entries (names ending in `/`) are left out.
///
/// Throws [FormatException] for what is not a zip archive this can read.
List<ZipEntry> readZip(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // The end record is 22 bytes plus a comment of at most 65535.
  var end = -1;
  for (
    var at = bytes.length - 22;
    at >= 0 && at >= bytes.length - 65557;
    at--
  ) {
    if (data.getUint32(at, Endian.little) == _endOfCentralDirectory) {
      end = at;
      break;
    }
  }
  if (end < 0) {
    throw const FormatException('no zip end of central directory record');
  }
  final count = data.getUint16(end + 10, Endian.little);
  var at = data.getUint32(end + 16, Endian.little);
  final entries = <ZipEntry>[];
  for (var i = 0; i < count; i++) {
    if (at + 46 > bytes.length ||
        data.getUint32(at, Endian.little) != _centralHeader) {
      throw FormatException('no central directory header at $at');
    }
    final method = data.getUint16(at + 10, Endian.little);
    final compressedSize = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final local = data.getUint32(at + 42, Endian.little);
    final name = String.fromCharCodes(bytes, at + 46, at + 46 + nameLength);
    at += 46 + nameLength + extraLength + commentLength;
    if (name.endsWith('/')) {
      continue;
    }
    if (local + 30 > bytes.length ||
        data.getUint32(local, Endian.little) != _localHeader) {
      throw FormatException('no local header for $name at $local');
    }
    final start =
        local +
        30 +
        data.getUint16(local + 26, Endian.little) +
        data.getUint16(local + 28, Endian.little);
    final stored = Uint8List.sublistView(bytes, start, start + compressedSize);
    entries.add(
      ZipEntry(name, switch (method) {
        0 => stored,
        8 => ZLibDecoder(raw: true).convert(stored),
        _ => throw FormatException('$name uses compression method $method'),
      }),
    );
  }
  return entries;
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

/// The CRC-32 of [bytes], as zip records it.
int crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

/// The zip archive of [entries], in the order given, each deflated (or
/// stored, when deflating does not make it smaller).
///
/// Throws [ArgumentError] for two entries with one name.
Uint8List writeZip(List<ZipEntry> entries) {
  final names = <String>{};
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var offset = 0;
  for (final entry in entries) {
    if (!names.add(entry.name)) {
      throw ArgumentError('two entries named ${entry.name}');
    }
    final name = entry.name.codeUnits;
    final crc = crc32(entry.bytes);
    final deflated = ZLibEncoder(raw: true, level: 6).convert(entry.bytes);
    final stored = deflated.length >= entry.bytes.length;
    final payload = stored ? entry.bytes : deflated;
    final method = stored ? 0 : 8;

    final local = ByteData(30)
      ..setUint32(0, _localHeader, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint16(10, _dosTime, Endian.little)
      ..setUint16(12, _dosDate, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, payload.length, Endian.little)
      ..setUint32(22, entry.bytes.length, Endian.little)
      ..setUint16(26, name.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(payload);

    final header = ByteData(46)
      ..setUint32(0, _centralHeader, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint16(12, _dosTime, Endian.little)
      ..setUint16(14, _dosDate, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, payload.length, Endian.little)
      ..setUint32(24, entry.bytes.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(name);
    offset += 30 + name.length + payload.length;
  }
  final directory = central.takeBytes();
  final end = ByteData(22)
    ..setUint32(0, _endOfCentralDirectory, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, directory.length, Endian.little)
    ..setUint32(16, offset, Endian.little);
  out
    ..add(directory)
    ..add(end.buffer.asUint8List());
  return out.takeBytes();
}
