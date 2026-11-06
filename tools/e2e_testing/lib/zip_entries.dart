/// How a zip archive (an APK, an App Bundle) stores its entries: what
/// extracting it loses.
library;

import 'dart:typed_data';

/// One entry of a zip archive's central directory.
class ZipEntry {
  ZipEntry(this.name, {required this.method, required this.dataOffset});

  /// The entry's path in the archive.
  final String name;

  /// The compression method: 0 is stored, 8 is deflated.
  final int method;

  /// Where the entry's data starts in the archive, after its local header.
  final int dataOffset;

  /// Whether the entry is stored uncompressed.
  bool get stored => method == 0;
}

const _endOfCentralDirectory = 0x06054b50;
const _centralHeader = 0x02014b50;
const _localHeader = 0x04034b50;

/// The entries of the zip archive [bytes], in central directory order.
///
/// Throws [FormatException] for what is not a zip archive, or one that needs
/// Zip64, which no APK does.
List<ZipEntry> zipEntries(Uint8List bytes) {
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
  final directory = data.getUint32(end + 16, Endian.little);
  if (count == 0xFFFF || directory == 0xFFFFFFFF) {
    throw const FormatException('Zip64 archives are not supported');
  }

  final entries = <ZipEntry>[];
  var at = directory;
  for (var i = 0; i < count; i++) {
    if (at + 46 > bytes.length ||
        data.getUint32(at, Endian.little) != _centralHeader) {
      throw FormatException('no central directory header at $at');
    }
    final method = data.getUint16(at + 10, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final local = data.getUint32(at + 42, Endian.little);
    final name = String.fromCharCodes(bytes, at + 46, at + 46 + nameLength);
    if (local + 30 > bytes.length ||
        data.getUint32(local, Endian.little) != _localHeader) {
      throw FormatException('no local header for $name at $local');
    }
    final localName = data.getUint16(local + 26, Endian.little);
    final localExtra = data.getUint16(local + 28, Endian.little);
    entries.add(
      ZipEntry(
        name,
        method: method,
        dataOffset: local + 30 + localName + localExtra,
      ),
    );
    at += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}
