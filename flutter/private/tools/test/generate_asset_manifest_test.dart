import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

// Import the library directly.
import '../generate_asset_manifest.dart';

void main() {
  group('encodeStandardMessage', () {
    test('encodes null to empty bytes', () {
      final result = encodeStandardMessage(null);
      expect(result, isEmpty);
    });

    test('encodes bool true to tag 1', () {
      final result = encodeStandardMessage(true);
      expect(result[0], 1); // _tagTrue
    });

    test('encodes bool false to tag 2', () {
      final result = encodeStandardMessage(false);
      expect(result[0], 2); // _tagFalse
    });

    test('encodes int32 to tag 3 + 4 bytes', () {
      final result = encodeStandardMessage(42);
      expect(result[0], 3); // _tagInt32
      expect(result.length, 5); // 1 tag + 4 bytes
      // Decode the int32 value.
      final bd = ByteData.sublistView(result, 1, 5);
      expect(bd.getInt32(0, Endian.host), 42);
    });

    test('encodes string to tag 7 + length + UTF-8 bytes', () {
      final result = encodeStandardMessage('hello');
      expect(result[0], 7); // _tagString
      expect(result[1], 5); // length of "hello" in UTF-8
      expect(utf8.decode(result.sublist(2)), 'hello');
    });

    test('encodes list to tag 12 + length + elements', () {
      final result = encodeStandardMessage([true, false]);
      expect(result[0], 12); // _tagList
      expect(result[1], 2); // 2 elements
      expect(result[2], 1); // true
      expect(result[3], 2); // false
    });

    test('encodes map to tag 13 + length + key-value pairs', () {
      final result = encodeStandardMessage({'a': true});
      expect(result[0], 13); // _tagMap
      expect(result[1], 1); // 1 entry
      // Key: string "a"
      expect(result[2], 7); // _tagString
      expect(result[3], 1); // length 1
      expect(result[4], 0x61); // 'a'
      // Value: true
      expect(result[5], 1); // _tagTrue
    });

    test('encodes nested asset manifest structure', () {
      // Simulate a real asset manifest: Map<String, List<Map<String, Object>>>
      final manifest = {
        'assets/logo.png': [
          {'asset': 'assets/logo.png'},
          {'asset': 'assets/2.0x/logo.png', 'dpr': 2.0},
        ],
      };
      final result = encodeStandardMessage(manifest);
      // Just verify it encodes without error and starts with map tag.
      expect(result[0], 13); // _tagMap
      expect(result.length, greaterThan(10));
    });

    test('writeSize encodes 1-byte, 2-byte, 4-byte sizes', () {
      // 1-byte: size < 254 — encode a short string
      final short = encodeStandardMessage('hi');
      expect(short[1], 2); // size fits in 1 byte

      // 2-byte: size 254..65535 — encode a long string
      final mediumStr = 'x' * 300;
      final medium = encodeStandardMessage(mediumStr);
      expect(medium[1], 254); // marker for 2-byte size

      // 4-byte: would need a huge string (65536+), skip for perf.
    });
  });

  group('iconUsesFromRecordings', () {
    // What frontend_server 3.50.0 wrote with --recorded-uses for an app with
    // Icon(Icons.add), Icon(Icons.close) and
    // const IconData(0xe001, fontFamily: 'Custom', fontPackage: 'pkg').
    // The same app with Icon(IconData(dynamicCode, fontFamily: 'MaterialIcons')).
    const flutter350NonConstant =
        r'''{"constants":[{"type":"non_constant"},{"type":"null"},{"type":"bool","value":false},{"type":"bool","value":true},{"type":"int","value":57345},{"type":"int","value":57415},{"type":"int","value":57501},{"type":"int","value":57502},{"type":"int","value":57706},{"type":"int","value":128842},{"type":"string","value":"Custom"},{"type":"string","value":"MaterialIcons"},{"type":"string","value":"pkg"},{"definition_index":0,"type":"instance","value":{"codePoint":4,"fontFamily":10,"fontFamilyFallback":1,"fontPackage":12,"matchTextDirection":2}},{"definition_index":0,"type":"instance","value":{"codePoint":5,"fontFamily":11,"fontFamilyFallback":1,"fontPackage":1,"matchTextDirection":2}},{"definition_index":0,"type":"instance","value":{"codePoint":6,"fontFamily":11,"fontFamilyFallback":1,"fontPackage":1,"matchTextDirection":3}},{"definition_index":0,"type":"instance","value":{"codePoint":7,"fontFamily":11,"fontFamilyFallback":1,"fontPackage":1,"matchTextDirection":3}},{"definition_index":0,"type":"instance","value":{"codePoint":8,"fontFamily":11,"fontFamilyFallback":1,"fontPackage":1,"matchTextDirection":2}},{"definition_index":0,"type":"instance","value":{"codePoint":9,"fontFamily":1,"fontFamilyFallback":1,"fontPackage":1,"matchTextDirection":2}}],"definitions":[{"path":[{"kind":"class","name":"IconData"}],"uri":"package:flutter/src/widgets/icon_data.dart"},{"path":[{"kind":"class","name":"IconData"},{"kind":"constructor","name":""}],"uri":"package:flutter/src/widgets/icon_data.dart"}],"loading_units":[{"name":"1"}],"uses":{"instances":[{"definition_index":0,"uses":[{"constant_index":13,"loading_unit_index":0,"type":"constant"},{"constant_index":14,"loading_unit_index":0,"type":"constant"},{"constant_index":15,"loading_unit_index":0,"type":"constant"},{"constant_index":16,"loading_unit_index":0,"type":"constant"},{"constant_index":17,"loading_unit_index":0,"type":"constant"},{"constant_index":18,"loading_unit_index":0,"type":"constant"},{"definition_index":1,"loading_unit_index":0,"named":{"fontFamily":11,"fontFamilyFallback":1,"fontPackage":1,"matchTextDirection":2},"positional":[0],"type":"creation"}]}]}}''';

    const flutter350 =
        r'''{"constants":[{"type":"null"},{"type":"bool","value":false},{"type":"bool","value":true},{"type":"int","value":57345},{"type":"int","value":57415},{"type":"int","value":57501},{"type":"int","value":57502},{"type":"int","value":57706},{"type":"int","value":128842},{"type":"string","value":"Custom"},{"type":"string","value":"MaterialIcons"},{"type":"string","value":"pkg"},{"definition_index":0,"type":"instance","value":{"codePoint":3,"fontFamily":9,"fontFamilyFallback":0,"fontPackage":11,"matchTextDirection":1}},{"definition_index":0,"type":"instance","value":{"codePoint":4,"fontFamily":10,"fontFamilyFallback":0,"fontPackage":0,"matchTextDirection":1}},{"definition_index":0,"type":"instance","value":{"codePoint":5,"fontFamily":10,"fontFamilyFallback":0,"fontPackage":0,"matchTextDirection":2}},{"definition_index":0,"type":"instance","value":{"codePoint":6,"fontFamily":10,"fontFamilyFallback":0,"fontPackage":0,"matchTextDirection":2}},{"definition_index":0,"type":"instance","value":{"codePoint":7,"fontFamily":10,"fontFamilyFallback":0,"fontPackage":0,"matchTextDirection":1}},{"definition_index":0,"type":"instance","value":{"codePoint":8,"fontFamily":0,"fontFamilyFallback":0,"fontPackage":0,"matchTextDirection":1}}],"definitions":[{"path":[{"kind":"class","name":"IconData"}],"uri":"package:flutter/src/widgets/icon_data.dart"}],"loading_units":[{"name":"1"}],"uses":{"instances":[{"definition_index":0,"uses":[{"constant_index":12,"loading_unit_index":0,"type":"constant"},{"constant_index":13,"loading_unit_index":0,"type":"constant"},{"constant_index":14,"loading_unit_index":0,"type":"constant"},{"constant_index":15,"loading_unit_index":0,"type":"constant"},{"constant_index":16,"loading_unit_index":0,"type":"constant"},{"constant_index":17,"loading_unit_index":0,"type":"constant"}]}]}}''';

    test('reads the constant IconData instances', () {
      final uses = iconUsesFromRecordings(
        json.decode(flutter350) as Map<String, dynamic>,
      );
      expect(uses['nonConstantLocations'], isEmpty);
      final instances = uses['constantInstances'] as List<Object?>;
      expect(instances, hasLength(6));
      expect(
        instances,
        contains(
          equals({
            'codePoint': 0xe001,
            'fontFamily': 'Custom',
            'fontPackage': 'pkg',
          }),
        ),
      );
      expect(
        instances,
        contains(
          equals({
            'codePoint': 57415,
            'fontFamily': 'MaterialIcons',
            'fontPackage': null,
          }),
        ),
      );
      // An IconData with no fontFamily is kept with a null family, as
      // const_finder reports it; the bundler skips it.
      expect(
        instances,
        contains(
          equals({
            'codePoint': 128842,
            'fontFamily': null,
            'fontPackage': null,
          }),
        ),
      );
    });

    Map<String, dynamic> withUse(Map<String, Object?> use) => {
      'constants': [
        {'type': 'int', 'value': 57415},
        {'type': 'string', 'value': 'MaterialIcons'},
      ],
      'definitions': [
        {
          'path': [
            {'kind': 'class', 'name': 'IconData'},
          ],
          'uri': 'package:flutter/src/widgets/icon_data.dart',
        },
        {
          'path': [
            {'kind': 'class', 'name': 'Other'},
          ],
          'uri': 'package:app/other.dart',
        },
      ],
      'uses': {
        'instances': [
          {
            'definition_index': 0,
            'uses': [use],
          },
          {
            'definition_index': 1,
            'uses': [
              {'type': 'tearoff', 'loading_unit_index': 0},
            ],
          },
        ],
      },
    };

    const constantCreation = {
      'type': 'creation',
      'definition_index': 0,
      'loading_unit_index': 0,
      'positional': [0],
      'named': {'fontFamily': 1},
    };

    test('reads a creation whose arguments are all constant', () {
      final uses = iconUsesFromRecordings(withUse(constantCreation));
      expect(uses['constantInstances'], [
        {
          'codePoint': 57415,
          'fontFamily': 'MaterialIcons',
          'fontPackage': null,
        },
      ]);
      // 'Other' has a tear-off, which would read as non-constant if counted.
      expect(uses['nonConstantLocations'], isEmpty);
    });

    test('a non-constant argument or a tear-off is non-constant', () {
      // What frontend_server 3.50.0 recorded for
      // Icon(IconData(dynamicCode, fontFamily: 'MaterialIcons')), where
      // dynamicCode is a runtime int: its codePoint argument is an index to a
      // {"type": "non_constant"} constant.
      final creation = iconUsesFromRecordings(
        json.decode(flutter350NonConstant) as Map<String, dynamic>,
      );
      expect(creation['nonConstantLocations'], hasLength(1));

      final tearoff = iconUsesFromRecordings(
        withUse({
          'type': 'tearoff',
          'definition_index': 0,
          'loading_unit_index': 0,
        }),
      );
      expect(tearoff['nonConstantLocations'], hasLength(1));
    });
  });
}
