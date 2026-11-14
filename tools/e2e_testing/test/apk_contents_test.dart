import 'dart:convert';
import 'dart:typed_data';

import 'package:rules_flutter_e2e_testing/apk_contents.dart';
import 'package:test/test.dart';

/// A dex file whose string table holds [descriptors], with a type for each;
/// only the first [defined] types have a class definition. The rest are
/// merely referenced, as `Ljava/lang/Object;` is.
Uint8List dex(List<String> descriptors, {required int defined}) {
  final n = descriptors.length;
  const header = 0x70;
  final stringIds = header;
  final typeIds = stringIds + 4 * n;
  final classDefs = typeIds + 4 * n;
  final stringData = classDefs + 32 * defined;
  final data = <int>[];
  final offsets = <int>[];
  for (final d in descriptors) {
    offsets.add(stringData + data.length);
    data
      ..add(d.length) // uleb128 UTF-16 length; every test string is < 128
      ..addAll(d.codeUnits)
      ..add(0);
  }
  final bytes = Uint8List(stringData + data.length);
  final view = ByteData.sublistView(bytes)
    ..setUint32(0x3c, stringIds, Endian.little)
    ..setUint32(0x44, typeIds, Endian.little)
    ..setUint32(0x60, defined, Endian.little)
    ..setUint32(0x64, classDefs, Endian.little);
  bytes.setRange(0, 4, [0x64, 0x65, 0x78, 0x0a]);
  for (var i = 0; i < n; i++) {
    view
      ..setUint32(stringIds + 4 * i, offsets[i], Endian.little)
      // Type i is described by string i.
      ..setUint32(typeIds + 4 * i, i, Endian.little);
  }
  for (var i = 0; i < defined; i++) {
    view.setUint32(classDefs + 32 * i, i, Endian.little);
  }
  bytes.setRange(stringData, stringData + data.length, data);
  return bytes;
}

/// A dex file defining one class, `LFoo;`, with the static fields
/// `DEBUG = true`, `BUILD_TYPE = "release"` and `COUNT = -2`, as the dex
/// format lays them out: a class_data_item names the static fields and the
/// class_def's static_values_off points to their initial values.
Uint8List dexWithStaticConstants() {
  const strings = ['LFoo;', 'DEBUG', 'BUILD_TYPE', 'release', 'COUNT'];
  const header = 0x70;
  final stringIds = header;
  final typeIds = stringIds + 4 * strings.length;
  final fieldIds = typeIds + 4;
  final classDefs = fieldIds + 8 * 3;
  final tail = classDefs + 32;

  final data = <int>[];
  final stringOffsets = <int>[];
  for (final string in strings) {
    stringOffsets.add(tail + data.length);
    data
      ..add(string.length)
      ..addAll(string.codeUnits)
      ..add(0);
  }
  final classData = tail + data.length;
  data.addAll([
    3, // static fields
    0, 0, 0, // instance fields, direct methods, virtual methods
    0, 0x19, // DEBUG: field id 0 (a difference of 0), public static final
    1, 0x19, // BUILD_TYPE: field id 1
    1, 0x19, // COUNT: field id 2
  ]);
  final staticValues = tail + data.length;
  data.addAll([
    3, // values
    0x3f, // boolean true: the value is the header's argument
    0x17, 3, // string, index 3 ("release")
    0x24, 0xfe, 0xff, // int, 2 bytes, little-endian -2
  ]);

  final bytes = Uint8List(tail + data.length);
  final view = ByteData.sublistView(bytes)
    ..setUint32(0x38, strings.length, Endian.little)
    ..setUint32(0x3c, stringIds, Endian.little)
    ..setUint32(0x44, typeIds, Endian.little)
    ..setUint32(0x50, 3, Endian.little)
    ..setUint32(0x54, fieldIds, Endian.little)
    ..setUint32(0x60, 1, Endian.little)
    ..setUint32(0x64, classDefs, Endian.little)
    ..setUint32(typeIds, 0, Endian.little) // type 0 is described by string 0
    ..setUint32(classDefs, 0, Endian.little)
    ..setUint32(classDefs + 24, classData, Endian.little)
    ..setUint32(classDefs + 28, staticValues, Endian.little);
  bytes.setRange(0, 4, [0x64, 0x65, 0x78, 0x0a]);
  for (var i = 0; i < strings.length; i++) {
    view.setUint32(stringIds + 4 * i, stringOffsets[i], Endian.little);
  }
  // field_id_item: class_idx u2, type_idx u2, name_idx u4.
  for (var i = 0; i < 3; i++) {
    view
      ..setUint16(fieldIds + 8 * i, 0, Endian.little)
      ..setUint32(
        fieldIds + 8 * i + 4,
        const [1, 2, 4][i],
        Endian.little,
      );
  }
  bytes.setRange(tail, tail + data.length, data);
  return bytes;
}

/// A compiled manifest holding an element per entry of [elements]: its name,
/// then its attributes, each a local name and a value: a string, or a bool,
/// which aapt2 compiles to a typed boolean with no raw string.
Uint8List axml(
  List<(String, Map<String, Object>)> elements, {
  bool utf8Pool = false,
}) {
  final pool = <String>[];
  int index(String s) {
    final at = pool.indexOf(s);
    if (at >= 0) return at;
    pool.add(s);
    return pool.length - 1;
  }

  final chunks = BytesBuilder();
  for (final (name, attributes) in elements) {
    final body = BytesBuilder()
      ..add(_u32(0xFFFFFFFF)) // namespace
      ..add(_u32(index(name)))
      ..add(_u16(20)) // attributeStart
      ..add(_u16(20)) // attributeSize
      ..add(_u16(attributes.length))
      ..add(_u16(0)) // idIndex
      ..add(_u16(0)) // classIndex
      ..add(_u16(0)); // styleIndex
    attributes.forEach((key, value) {
      body
        ..add(_u32(0xFFFFFFFF)) // namespace
        ..add(_u32(index(key)));
      if (value is bool) {
        body
          ..add(_u32(0xFFFFFFFF)) // no rawValue
          ..add(_u16(8)) // typed value size
          ..addByte(0)
          ..addByte(0x12) // TYPE_INT_BOOLEAN
          ..add(_u32(value ? 0xFFFFFFFF : 0));
      } else {
        body
          ..add(_u32(index(value as String))) // rawValue
          ..add(_u16(8)) // typed value size
          ..addByte(0)
          ..addByte(0x03) // TYPE_STRING
          ..add(_u32(index(value)));
      }
    });
    final b = body.toBytes();
    chunks
      ..add(_u16(0x0102))
      ..add(_u16(16))
      ..add(_u32(16 + b.length))
      ..add(_u32(1)) // line number
      ..add(_u32(0xFFFFFFFF)) // comment
      ..add(b);
  }

  final strings = BytesBuilder();
  final offsets = <int>[];
  for (final s in pool) {
    offsets.add(strings.length);
    if (utf8Pool) {
      final encoded = utf8.encode(s);
      strings
        ..addByte(s.length)
        ..addByte(encoded.length)
        ..add(encoded)
        ..addByte(0);
    } else {
      strings
        ..add(_u16(s.length))
        ..add([for (final u in s.codeUnits) ..._u16(u)])
        ..add(_u16(0));
    }
  }
  final stringBytes = strings.toBytes();
  final stringsStart = 28 + 4 * pool.length;
  final poolChunk = BytesBuilder()
    ..add(_u16(0x0001))
    ..add(_u16(28))
    ..add(_u32(stringsStart + stringBytes.length))
    ..add(_u32(pool.length))
    ..add(_u32(0)) // style count
    ..add(_u32(utf8Pool ? 0x100 : 0))
    ..add(_u32(stringsStart))
    ..add(_u32(0)); // styles start
  for (final o in offsets) {
    poolChunk.add(_u32(o));
  }
  poolChunk.add(stringBytes);

  final pc = poolChunk.toBytes();
  final cs = chunks.toBytes();
  return (BytesBuilder()
        ..add(_u16(0x0003))
        ..add(_u16(8))
        ..add(_u32(8 + pc.length + cs.length))
        ..add(pc)
        ..add(cs))
      .toBytes();
}

List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];

List<int> _u32(int v) => [
  v & 0xff,
  (v >> 8) & 0xff,
  (v >> 16) & 0xff,
  (v >> 24) & 0xff,
];

void main() {
  group('dexClassDescriptors', () {
    test('lists defined classes, not merely referenced types', () {
      final bytes = dex([
        'Lcom/example/Main;',
        'Lcom/example/Other;',
        'Ljava/lang/Object;',
      ], defined: 2);
      expect(dexClassDescriptors(bytes), {
        'Lcom/example/Main;',
        'Lcom/example/Other;',
      });
    });

    test('is empty for a dex that defines nothing', () {
      expect(
        dexClassDescriptors(dex(['Ljava/lang/Object;'], defined: 0)),
        isEmpty,
      );
    });

    test('rejects bytes that are not a dex file', () {
      expect(() => dexClassDescriptors(Uint8List(0x80)), throwsFormatException);
      expect(() => dexClassDescriptors(Uint8List(4)), throwsFormatException);
    });
  });

  group('dexStaticConstants', () {
    test('reads the initial values of static fields, by class and name', () {
      expect(dexStaticConstants(dexWithStaticConstants()), {
        'LFoo;': {'DEBUG': true, 'BUILD_TYPE': 'release', 'COUNT': -2},
      });
    });

    test('skips a class with no static values', () {
      expect(dexStaticConstants(dex(['LFoo;'], defined: 1)), isEmpty);
    });

    test('rejects what is not a dex file', () {
      expect(() => dexStaticConstants(Uint8List(0x80)), throwsFormatException);
    });
  });

  group('manifestElements', () {
    final manifest = axml([
      ('manifest', {'package': 'com.example.app'}),
      ('uses-permission', {'name': 'android.permission.INTERNET'}),
      ('uses-permission-sdk-23', {'name': 'android.permission.CAMERA'}),
      ('uses-feature', {'name': 'android.hardware.camera'}),
      ('activity', {'name': 'com.example.app.MainActivity'}),
    ]);

    test('reads elements in order with their string attributes', () {
      final elements = manifestElements(manifest);
      expect(elements.map((e) => e.name), [
        'manifest',
        'uses-permission',
        'uses-permission-sdk-23',
        'uses-feature',
        'activity',
      ]);
      expect(elements.first.attributes['package'], 'com.example.app');
      expect(
        elements.last.attributes['name'],
        'com.example.app.MainActivity',
      );
    });

    test('reads a UTF-8 string pool', () {
      final elements = manifestElements(
        axml([
          ('manifest', {'package': 'com.example.app'}),
        ], utf8Pool: true),
      );
      expect(elements.single.attributes['package'], 'com.example.app');
    });

    test('reads a boolean attribute as true or false', () {
      final elements = manifestElements(
        axml([
          ('application', {'debuggable': true, 'extractNativeLibs': false}),
        ]),
      );
      expect(elements.single.attributes, {
        'debuggable': 'true',
        'extractNativeLibs': 'false',
      });
    });

    test('usesPermissions names the permissions and nothing else', () {
      expect(usesPermissions(manifest), {
        'android.permission.INTERNET',
        'android.permission.CAMERA',
      });
    });

    test('a permission without a name is an error', () {
      expect(
        () => usesPermissions(axml([('uses-permission', <String, String>{})])),
        throwsFormatException,
      );
    });

    test('rejects what is not AXML rather than finding nothing', () {
      expect(() => manifestElements(Uint8List(4)), throwsFormatException);
      final truncated = Uint8List.sublistView(manifest, 0, manifest.length - 4);
      expect(() => manifestElements(truncated), throwsFormatException);
    });
  });

  group('containsText', () {
    test('finds UTF-8 and UTF-16LE encodings', () {
      expect(
        containsText('xx android.permission.X yy'.codeUnits, 'permission'),
        isTrue,
      );
      expect(
        containsText([0, 0x70, 0, 0x65, 0, 0x72, 0], 'per'),
        isTrue,
      );
      expect(containsText('permission'.codeUnits, 'absent'), isFalse);
    });
  });
}
