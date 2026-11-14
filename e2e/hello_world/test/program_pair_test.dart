// Run through the Tier-2 pair, `flutter_test_program` and
// `flutter_program_test`, as a program compiled elsewhere would be: a golden
// comparison against a declared PNG, and `@Tags` selection.
//
// The program is compiled once and run by `:program_pair_test`, which excludes
// `slow`, so the case that fails when it runs shows the selection is applied.
// The golden is a solid colour, which renders alike on every host.
@Tags(['library_tag'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a golden case', (tester) async {
    await tester.pumpWidget(
      const Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: ColoredBox(color: Color(0xFF2196F3)),
        ),
      ),
    );
    await expectLater(
      find.byType(ColoredBox),
      matchesGoldenFile('goldens/program_pair_box.png'),
    );
  }, tags: 'golden');

  test('a slow case', () {
    fail('excluded by exclude_tags, so it does not run');
  }, tags: ['slow']);

  test('an untagged case', () {});
}
