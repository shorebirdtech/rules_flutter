import 'dart:typed_data';

import 'package:test/test.dart';

import '../merge_plists.dart';
import '../plist_binary.dart';
import 'binary_plist_fixture.dart';

/// The entries of a plist as key to value XML with whitespace removed, so a
/// comparison ignores the indentation of nested values.
Map<String, String> _entries(String xml) => {
  for (final e in parsePlist(xml, 'x.plist'))
    e.key: e.rawValue.replaceAll(RegExp(r'\s+'), ''),
};

void main() {
  test('recognises the binary header only', () {
    expect(isBinaryPlist(fixtureBinary()), isTrue);
    expect(isBinaryPlist('<?xml version="1.0"?>'.codeUnits), isFalse);
    expect(isBinaryPlist('bplist0'.codeUnits), isFalse);
  });

  test('converts every value type to the XML plist it was made from', () {
    expect(
      _entries(binaryPlistToXml(fixtureBinary())),
      _entries(fixtureXml),
    );
  });

  test('keeps the entities and non-ASCII text of a string', () {
    final entries = _entries(binaryPlistToXml(fixtureBinary()));
    expect(entries['CFBundleName'], '<string>A&amp;B</string>');
    expect(entries['Accent'], '<string>café</string>');
  });

  test('rejects a plist that is cut short', () {
    expect(
      () => binaryPlistToXml(
        Uint8List.sublistView(fixtureBinary(), 0, 60),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('malformed binary plist'),
        ),
      ),
    );
  });

  test('rejects a plist with a zeroed trailer', () {
    final bytes = fixtureBinary();
    bytes.fillRange(bytes.length - 32, bytes.length, 0);
    expect(() => binaryPlistToXml(bytes), throwsFormatException);
  });
}
