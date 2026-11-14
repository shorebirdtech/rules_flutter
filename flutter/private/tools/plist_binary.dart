/// Reads a binary property list (`bplist00`) as the XML plist it stands for.
///
/// Xcode, `plutil -convert binary1` and some editors save an Info.plist in the
/// binary format. The tools that read plists (`merge_plists.dart`,
/// `check_apple_version_keys.dart`) parse XML, so they convert a binary plist
/// here first and then take the one XML path. Every property list type an XML
/// plist can hold is carried over, so a merge of a binary plist keeps all of
/// its values.
///
/// It has no dependencies beyond the Dart SDK.
import 'dart:convert';
import 'dart:typed_data';

/// Whether [bytes] begin a binary property list.
bool isBinaryPlist(List<int> bytes) =>
    bytes.length >= 8 &&
    ascii.decode(bytes.sublist(0, 8), allowInvalid: true) == 'bplist00';

/// The XML plist document equal to the binary plist [b].
///
/// Throws [FormatException] with a message beginning "malformed binary plist"
/// when [b] is not a well-formed binary plist, or holds a value (a null, a
/// UID) that has no XML form.
String binaryPlistToXml(Uint8List b) {
  Never bad(String why) =>
      throw FormatException('malformed binary plist: $why.');

  if (b.length < 40) bad('it is too short');
  int uint(int offset, int size) {
    if (offset < 0 || size < 0 || offset + size > b.length) {
      bad('an offset is past the end');
    }
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = (v << 8) | b[offset + i];
    }
    return v;
  }

  final trailer = b.length - 32;
  final offsetSize = b[trailer + 6];
  final refSize = b[trailer + 7];
  final count = uint(trailer + 8, 8);
  final top = uint(trailer + 16, 8);
  final table = uint(trailer + 24, 8);
  if (offsetSize < 1 || offsetSize > 8 || refSize < 1 || refSize > 8) {
    bad('its trailer sizes are invalid');
  }
  if (top >= count) bad('its top object does not exist');

  int offsetOf(int object) {
    if (object >= count) bad('an object reference is out of range');
    final at = uint(table + object * offsetSize, offsetSize);
    if (at >= b.length) bad('an offset is past the end');
    return at;
  }

  // The length in a marker's low nibble, or the integer object that follows
  // when the nibble is 0xF. Returns (length, offset of what comes next).
  (int, int) lengthAt(int at) {
    final low = b[at] & 0x0f;
    if (low != 0x0f) return (low, at + 1);
    uint(at, 2);
    final intMarker = b[at + 1];
    if (intMarker >> 4 != 0x1) bad('a length is not an integer');
    final size = 1 << (intMarker & 0x0f);
    return (uint(at + 2, size), at + 2 + size);
  }

  Uint8List slice(int start, int n) {
    if (start < 0 || n < 0 || start + n > b.length) {
      bad('an object runs past the end');
    }
    return Uint8List.sublistView(b, start, start + n);
  }

  String text(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String real(double v) {
    if (v.isNaN) return 'nan';
    if (v.isInfinite) return v.isNegative ? '-infinity' : '+infinity';
    return v.toString();
  }

  final active = <int>{};

  // The text of a string object, or null when [object] is not a string.
  String? stringAt(int object) {
    final at = offsetOf(object);
    switch (b[at] >> 4) {
      case 0x5:
        final (n, start) = lengthAt(at);
        return ascii.decode(slice(start, n), allowInvalid: true);
      case 0x7:
        final (n, start) = lengthAt(at);
        return utf8.decode(slice(start, n), allowMalformed: true);
      case 0x6:
        final (n, start) = lengthAt(at);
        slice(start, n * 2);
        return String.fromCharCodes([
          for (var i = 0; i < n; i++) uint(start + 2 * i, 2),
        ]);
    }
    return null;
  }

  // The XML of [object], one element, its inner lines indented from [depth].
  String element(int object, int depth) {
    final at = offsetOf(object);
    final marker = b[at];
    final pad = '\t' * depth;
    final string = stringAt(object);
    if (string != null) return '<string>${text(string)}</string>';
    switch (marker >> 4) {
      case 0x0:
        if (marker == 0x08) return '<false/>';
        if (marker == 0x09) return '<true/>';
        return bad('it holds a null value, which an XML plist cannot');
      case 0x1:
        final size = 1 << (marker & 0x0f);
        if (size > 8) bad('it holds an integer wider than 64 bits');
        final raw = uint(at + 1, size);
        // Eight-byte integers are signed; shorter ones are not.
        return '<integer>${size == 8 ? raw.toSigned(64) : raw}</integer>';
      case 0x2:
        final size = 1 << (marker & 0x0f);
        final data = ByteData.sublistView(slice(at + 1, size));
        if (size == 4) return '<real>${real(data.getFloat32(0))}</real>';
        if (size == 8) return '<real>${real(data.getFloat64(0))}</real>';
        return bad('it holds a real number of an unknown width');
      case 0x3:
        final seconds = ByteData.sublistView(slice(at + 1, 8)).getFloat64(0);
        if (!seconds.isFinite) bad('it holds a date that is not finite');
        final date = DateTime.utc(
          2001,
        ).add(Duration(microseconds: (seconds * 1e6).round()));
        final iso = date.toIso8601String().replaceFirst(RegExp(r'\.0+Z$'), 'Z');
        return '<date>$iso</date>';
      case 0x4:
        final (n, start) = lengthAt(at);
        return '<data>${base64.encode(slice(start, n))}</data>';
      case 0x8:
        return bad('it holds a UID, which an XML plist cannot');
      case 0xA:
      case 0xC:
        final (n, start) = lengthAt(at);
        if (!active.add(object)) bad('an object contains itself');
        final items = [
          for (var i = 0; i < n; i++)
            '$pad\t${element(uint(start + i * refSize, refSize), depth + 1)}',
        ];
        active.remove(object);
        return items.isEmpty
            ? '<array/>'
            : '<array>\n${items.join('\n')}\n$pad</array>';
      case 0xD:
        final (n, start) = lengthAt(at);
        if (!active.add(object)) bad('an object contains itself');
        final items = <String>[];
        for (var i = 0; i < n; i++) {
          final key = stringAt(uint(start + i * refSize, refSize));
          if (key == null) bad('a dictionary key is not text');
          items
            ..add('$pad\t<key>${text(key)}</key>')
            ..add(
              '$pad\t${element(uint(start + (n + i) * refSize, refSize), depth + 1)}',
            );
        }
        active.remove(object);
        return items.isEmpty
            ? '<dict/>'
            : '<dict>\n${items.join('\n')}\n$pad</dict>';
      default:
        return bad('it holds an object of an unknown type');
    }
  }

  final root = element(top, 0);
  if (!root.startsWith('<dict')) bad('its root is not a dictionary');
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      '<plist version="1.0">\n$root\n</plist>\n';
}
