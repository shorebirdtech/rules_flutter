import 'package:test/test.dart';

import '../apple_xcframeworks_codesign.dart';

void main() {
  test('signs as upstream: no timestamp but in release', () {
    expect(codesignArguments('X.xcframework', 'Apple Development', 'Debug'), [
      '--force',
      '--sign',
      'Apple Development',
      '--timestamp=none',
      'X.xcframework',
    ]);
    expect(codesignArguments('X.xcframework', '-', 'Release'), [
      '--force',
      '--sign',
      '-',
      'X.xcframework',
    ]);
  });

  test('refuses an incomplete command line', () {
    expect(run(['--input', 'a', '--output', 'b']), 64);
  });
}
