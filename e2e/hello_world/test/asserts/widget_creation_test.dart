// Widget creation locations are tracked in a `flutter_test`, as they are under
// `flutter test` (which compiles with `--track-widget-creation`): a widget
// built in this file knows it was, and says where. The inspector and the
// "relevant error-causing widget" line of a failure message read this.
//
// `//:widget_creation_test` runs this in both kernel modes and in `-c fastbuild`
// and `-c dbg`; see the variants beside it in BUILD.bazel.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _creationLocation(Widget widget) {
  final json = widget.toDiagnosticsNode().toJsonMap(
    InspectorSerializationDelegate(service: WidgetInspectorService.instance),
  );
  final location = json['creationLocation'];
  expect(
    location,
    isA<Map<String, Object?>>(),
    reason: 'no creation location recorded for $widget',
  );
  return location! as Map<String, Object?>;
}

void main() {
  test('the framework reports widget creation as tracked', () {
    expect(WidgetInspectorService.instance.isWidgetCreationTracked(), isTrue);
  });

  test('a widget built in the test is a local creation', () {
    const widget = SizedBox();
    expect(debugIsWidgetLocalCreation(widget), isTrue);
    expect(debugIsLocalCreationLocation(widget), isTrue);
  });

  test("a widget's creation location names the file that built it", () {
    final location = _creationLocation(SizedBox(key: UniqueKey()));
    expect(location['file'], endsWith('widget_creation_test.dart'));
    expect(location['line'], isA<int>());
  });

  testWidgets('a mounted element is located through its widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(textDirection: TextDirection.ltr, child: Text('x')),
    );
    final element = tester.element(find.text('x'));
    expect(debugIsLocalCreationLocation(element), isTrue);
  });
}
