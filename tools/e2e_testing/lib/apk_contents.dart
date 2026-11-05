/// Readers for what a built APK contains: its compiled AndroidManifest.xml
/// and the classes its dex files define.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';

/// Whether [bytes] contain [needle] encoded as UTF-8 or as UTF-16LE.
///
/// Binary Android artifacts mix both: aapt2 emits UTF-8 string pools in
/// `resources.arsc` but UTF-16 in binary XML. This finds a string anywhere,
/// without parsing; use [manifestElements] to know where in a manifest it is.
bool containsText(List<int> bytes, String needle) =>
    containsBytes(bytes, needle.codeUnits) ||
    containsBytes(bytes, utf16leBytes(needle));

/// Parses a dex file and returns the descriptors of all classes it defines
/// (class_defs entries — not merely referenced types).
///
/// Dex layout (all offsets little-endian, per the Dalvik executable format):
/// the header locates the string_ids, type_ids, and class_defs tables. Each
/// class_def_item begins with a u4 index into type_ids; each type_id_item is
/// a u4 index into string_ids; each string_id_item is a u4 offset to string
/// data (uleb128 UTF-16 length followed by MUTF-8 bytes). Class descriptors
/// are ASCII, so MUTF-8 decoding reduces to reading until the NUL terminator.
Set<String> definedClassDescriptors(File dexFile) {
  try {
    return dexClassDescriptors(dexFile.readAsBytesSync());
  } on FormatException catch (e) {
    throw FormatException('${dexFile.path}: ${e.message}');
  }
}

/// [definedClassDescriptors] for the bytes of a dex file.
Set<String> dexClassDescriptors(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  const dexMagic = [0x64, 0x65, 0x78, 0x0a]; // "dex\n"
  if (bytes.length < 0x70) {
    throw const FormatException('too short to be a dex file');
  }
  for (var i = 0; i < dexMagic.length; i++) {
    if (bytes[i] != dexMagic[i]) {
      throw const FormatException('not a dex file');
    }
  }
  final stringIdsOff = data.getUint32(0x3c, Endian.little);
  final typeIdsOff = data.getUint32(0x44, Endian.little);
  final classDefsSize = data.getUint32(0x60, Endian.little);
  final classDefsOff = data.getUint32(0x64, Endian.little);

  String stringAt(int stringIdx) {
    var off = data.getUint32(stringIdsOff + 4 * stringIdx, Endian.little);
    // Skip the uleb128 UTF-16 length prefix.
    while (bytes[off] & 0x80 != 0) {
      off++;
    }
    off++;
    final end = bytes.indexOf(0, off);
    return String.fromCharCodes(bytes.sublist(off, end));
  }

  final descriptors = <String>{};
  for (var i = 0; i < classDefsSize; i++) {
    // class_def_item is 8 u4 fields; the first is the type_ids index.
    final typeIdx = data.getUint32(classDefsOff + 32 * i, Endian.little);
    final descriptorIdx = data.getUint32(
      typeIdsOff + 4 * typeIdx,
      Endian.little,
    );
    descriptors.add(stringAt(descriptorIdx));
  }
  return descriptors;
}

/// The compile-time constants of every class the dex file defines: its static
/// fields that carry an initial value, keyed by class descriptor and then
/// field name. A value is a [bool], an [int], a [double], a [String] or null.
///
/// This is where `static final` constants of a primitive or string type live
/// (`BuildConfig.DEBUG`, `BuildConfig.BUILD_TYPE`): a class_def_item's
/// `static_values_off` points to an encoded_array of the initial values of its
/// static fields, in the order the class_data_item lists those fields.
/// A static field the array does not reach has the default value and is not
/// listed.
Map<String, Map<String, Object?>> dexStaticConstants(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 0x70 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'dex\n') {
    throw const FormatException('not a dex file');
  }
  final stringIdsOff = data.getUint32(0x3c, Endian.little);
  final typeIdsOff = data.getUint32(0x44, Endian.little);
  final fieldIdsOff = data.getUint32(0x54, Endian.little);
  final classDefsSize = data.getUint32(0x60, Endian.little);
  final classDefsOff = data.getUint32(0x64, Endian.little);

  var at = 0;
  int uleb() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = bytes[at++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  // Reads a string without moving the cursor.
  String stringAt(int stringIdx) {
    final resume = at;
    at = data.getUint32(stringIdsOff + 4 * stringIdx, Endian.little);
    uleb(); // UTF-16 length
    final end = bytes.indexOf(0, at);
    final value = utf8.decode(bytes.sublist(at, end), allowMalformed: true);
    at = resume;
    return value;
  }

  String typeAt(int typeIdx) => stringAt(
    data.getUint32(typeIdsOff + 4 * typeIdx, Endian.little),
  );

  String fieldNameAt(int fieldIdx) =>
      stringAt(data.getUint32(fieldIdsOff + 8 * fieldIdx + 4, Endian.little));

  // The size-prefixed little-endian integer an encoded_value carries.
  int sized(int size, {required bool signed}) {
    var v = 0;
    for (var i = 0; i < size; i++) {
      v |= bytes[at + i] << (8 * i);
    }
    at += size;
    if (signed && size < 8 && size > 0 && (v >> (8 * size - 1)) & 1 == 1) {
      v -= 1 << (8 * size);
    }
    return v;
  }

  Object? encodedValue() {
    final header = bytes[at++];
    final type = header & 0x1f;
    final size = (header >> 5) + 1;
    switch (type) {
      case 0x00: // byte
      case 0x02: // short
      case 0x04: // int
      case 0x06: // long
        return sized(size, signed: true);
      case 0x03: // char
        return sized(size, signed: false);
      case 0x10: // float: the high bytes are stored, the low ones are zero
        final raw = sized(size, signed: false) << (8 * (4 - size));
        return (ByteData(4)..setUint32(0, raw, Endian.little)).getFloat32(
          0,
          Endian.little,
        );
      case 0x11: // double
        final raw = sized(size, signed: false) << (8 * (8 - size));
        return (ByteData(8)..setUint64(0, raw, Endian.little)).getFloat64(
          0,
          Endian.little,
        );
      case 0x17: // string
        return stringAt(sized(size, signed: false));
      case 0x1e: // null
        return null;
      case 0x1f: // boolean: the value is the header's argument
        return (header >> 5) == 1;
    }
    throw FormatException('unsupported dex encoded_value type 0x$type');
  }

  final constants = <String, Map<String, Object?>>{};
  for (var i = 0; i < classDefsSize; i++) {
    final def = classDefsOff + 32 * i;
    final classDataOff = data.getUint32(def + 24, Endian.little);
    final staticValuesOff = data.getUint32(def + 28, Endian.little);
    if (classDataOff == 0 || staticValuesOff == 0) continue;
    final descriptor = typeAt(data.getUint32(def, Endian.little));

    at = classDataOff;
    final staticFields = uleb();
    uleb(); // instance fields
    uleb(); // direct methods
    uleb(); // virtual methods
    final names = <String>[];
    var fieldIdx = 0;
    for (var f = 0; f < staticFields; f++) {
      fieldIdx += uleb();
      uleb(); // access flags
      names.add(fieldNameAt(fieldIdx));
    }

    at = staticValuesOff;
    final count = uleb();
    final values = <String, Object?>{};
    for (var v = 0; v < count && v < names.length; v++) {
      values[names[v]] = encodedValue();
    }
    constants[descriptor] = values;
  }
  return constants;
}

// -- Binary XML (AXML) reader -------------------------------------------------
//
// Android compiles AndroidManifest.xml into the resource-chunk format
// documented by AOSP's ResourceTypes.h. Only what this test needs is
// implemented: the string pool, and START_ELEMENT chunks with their
// attributes. Anything unexpected is a hard error rather than a silent
// empty result, so a manifest this reader cannot account for can never be
// mistaken for one that declares nothing.

const _chunkStringPool = 0x0001;
const _chunkXmlStartElement = 0x0102;
const _typeString = 0x03;
const _typeIntDec = 0x10;
const _typeIntHex = 0x11;

/// Every element of a compiled [manifest], in document order, with its
/// string- and integer-valued attributes keyed by local name (`name`, not
/// `android:name`). An integer, such as `versionCode`, is in decimal.
List<ManifestElement> manifestElements(Uint8List manifest) {
  final data = ByteData.sublistView(manifest);
  if (manifest.length < 8) {
    throw const FormatException('AndroidManifest.xml is too short to be AXML');
  }

  List<String>? pool;
  final elements = <ManifestElement>[];

  // Walk top-level chunks after the 8-byte file header.
  var offset = data.getUint16(2, Endian.little);
  while (offset + 8 <= manifest.length) {
    final type = data.getUint16(offset, Endian.little);
    final headerSize = data.getUint16(offset + 2, Endian.little);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    if (chunkSize < 8 || offset + chunkSize > manifest.length) {
      throw FormatException(
        'AXML chunk at $offset declares an out-of-range size $chunkSize',
      );
    }

    if (type == _chunkStringPool) {
      pool = _readStringPool(data, manifest, offset);
    } else if (type == _chunkXmlStartElement) {
      if (pool == null) {
        throw const FormatException(
          'AXML START_ELEMENT appears before the string pool',
        );
      }
      elements.add(_readStartElement(data, offset, headerSize, pool));
    }

    offset += chunkSize;
  }

  if (pool == null) {
    throw const FormatException('AndroidManifest.xml has no AXML string pool');
  }
  return elements;
}

/// The `android:name` values of every `<uses-permission>` /
/// `<uses-permission-sdk-23>` element in a compiled [manifest].
Set<String> usesPermissions(Uint8List manifest) => {
  for (final element in manifestElements(manifest))
    if (element.name == 'uses-permission' ||
        element.name == 'uses-permission-sdk-23')
      element.attributes['name'] ??
          (throw FormatException(
            'AXML <${element.name}> has no android:name attribute',
          )),
};

/// One element of a compiled manifest.
class ManifestElement {
  ManifestElement(this.name, this.attributes);

  final String name;
  final Map<String, String> attributes;
}

ManifestElement _readStartElement(
  ByteData data,
  int offset,
  int headerSize,
  List<String> pool,
) {
  String stringAt(int index) =>
      index == 0xFFFFFFFF || index >= pool.length ? '' : pool[index];

  final body = offset + headerSize;
  final nameIndex = data.getUint32(body + 4, Endian.little);
  final attributeStart = data.getUint16(body + 8, Endian.little);
  final attributeSize = data.getUint16(body + 10, Endian.little);
  final attributeCount = data.getUint16(body + 12, Endian.little);

  final attributes = <String, String>{};
  for (var i = 0; i < attributeCount; i++) {
    final at = body + attributeStart + i * attributeSize;
    final attrName = stringAt(data.getUint32(at + 4, Endian.little));
    final rawValue = data.getUint32(at + 8, Endian.little);
    final dataType = data.getUint8(at + 15);
    final typedData = data.getUint32(at + 16, Endian.little);
    if (rawValue != 0xFFFFFFFF) {
      attributes[attrName] = stringAt(rawValue);
    } else if (dataType == _typeString) {
      attributes[attrName] = stringAt(typedData);
    } else if (dataType == _typeIntDec || dataType == _typeIntHex) {
      attributes[attrName] = typedData.toSigned(32).toString();
    }
  }

  return ManifestElement(stringAt(nameIndex), attributes);
}

List<String> _readStringPool(ByteData data, Uint8List bytes, int offset) {
  final stringCount = data.getUint32(offset + 8, Endian.little);
  final flags = data.getUint32(offset + 16, Endian.little);
  final stringsStart = data.getUint32(offset + 20, Endian.little);
  final isUtf8 = (flags & 0x100) != 0;

  final strings = <String>[];
  for (var i = 0; i < stringCount; i++) {
    final entryOffset = data.getUint32(offset + 28 + i * 4, Endian.little);
    var at = offset + stringsStart + entryOffset;
    if (isUtf8) {
      // Two length prefixes (UTF-16 length, then byte length), each 1 or 2
      // bytes: a leading high bit means the value spans two bytes.
      at = _skipUtf8Length(data, at);
      final (byteLength, contentAt) = _readUtf8Length(data, at);
      strings.add(
        utf8.decode(
          bytes.sublist(contentAt, contentAt + byteLength),
          allowMalformed: true,
        ),
      );
    } else {
      var length = data.getUint16(at, Endian.little);
      at += 2;
      if ((length & 0x8000) != 0) {
        length = ((length & 0x7FFF) << 16) | data.getUint16(at, Endian.little);
        at += 2;
      }
      final units = <int>[
        for (var c = 0; c < length; c++)
          data.getUint16(at + c * 2, Endian.little),
      ];
      strings.add(String.fromCharCodes(units));
    }
  }
  return strings;
}

int _skipUtf8Length(ByteData data, int at) =>
    (data.getUint8(at) & 0x80) != 0 ? at + 2 : at + 1;

(int, int) _readUtf8Length(ByteData data, int at) {
  final first = data.getUint8(at);
  if ((first & 0x80) != 0) {
    return (((first & 0x7F) << 8) | data.getUint8(at + 1), at + 2);
  }
  return (first, at + 1);
}
