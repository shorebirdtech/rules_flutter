import 'dart:typed_data';

/// The XML plist the binary fixture below was made from: every value type an
/// XML plist holds, a string needing entity escapes, and a non-ASCII one.
const fixtureXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>A&amp;B</string>
	<key>Accent</key>
	<string>café</string>
	<key>Count</key>
	<integer>-7</integer>
	<key>Big</key>
	<integer>70000</integer>
	<key>Ratio</key>
	<real>1.5</real>
	<key>On</key>
	<true/>
	<key>Off</key>
	<false/>
	<key>When</key>
	<date>2024-03-05T06:07:08Z</date>
	<key>Blob</key>
	<data>AQID</data>
	<key>Modes</key>
	<array>
		<string>one</string>
		<string>two</string>
	</array>
	<key>Nested</key>
	<dict>
		<key>Inner</key>
		<array>
			<integer>1</integer>
		</array>
	</dict>
	<key>EmptyArray</key>
	<array/>
</dict>
</plist>
''';

/// `fixtureXml` after `plutil -convert binary1`.
const _fixtureHex =
    '62706c6973743030dc0102030405060708090a0b0c0d0e0f12131418191a1b1c1d534269'
    '675a456d7074794172726179554d6f64657356416363656e7454426c6f62564e65737465'
    '64534f666655436f756e74524f6e55526174696f545768656e5c434642756e646c654e61'
    '6d651200011170a0a21011536f6e655374776f6400630061006600e943010203d1151655'
    '496e6e6572a11710010813fffffffffffffff909233ff80000000000003341c5cb770600'
    '00005341264208212530363d42494d53565c616e7374777b7f888c8f9597999aa3a4adb6'
    '0000000000000101000000000000001e000000000000000000000000000000ba';

Uint8List fixtureBinary() => hex(_fixtureHex);

Uint8List hex(String digits) => Uint8List.fromList([
  for (var i = 0; i < digits.length; i += 2)
    int.parse(digits.substring(i, i + 2), radix: 16),
]);
