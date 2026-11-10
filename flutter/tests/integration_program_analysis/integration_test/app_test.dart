import 'package:flutter_test/flutter_test.dart';
import 'package:integration_program_analysis/main.dart' as app;

void main() {
  testWidgets('the app starts', (tester) async {
    app.main();
    await tester.pump();
  });
}
