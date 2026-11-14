import 'dart:io';

import 'package:test/test.dart';

import '../ios_code_asset_post_processor.dart';

void main() {
  late Directory work;
  late String app;
  setUp(() {
    work = Directory.systemTemp.createTempSync('post_processor');
    app = '${work.path}/Payload/Runner.app';
    for (final name in ['kept', 'dropped']) {
      File('$app/Frameworks/$name.framework/$name').createSync(recursive: true);
    }
  });
  tearDown(() => work.deleteSync(recursive: true));

  test('removes the listed frameworks and the list', () {
    File('$app/$droppedFrameworksFile')
        .writeAsStringSync('dropped.framework\n');
    expect(removeDroppedFrameworks(work), [
      'Runner.app/Frameworks/dropped.framework',
    ]);
    expect(
      Directory('$app/Frameworks/dropped.framework').existsSync(),
      isFalse,
    );
    expect(Directory('$app/Frameworks/kept.framework').existsSync(), isTrue);
    expect(File('$app/$droppedFrameworksFile').existsSync(), isFalse);
  });

  test('removes nothing for an empty list, and the list', () {
    File('$app/$droppedFrameworksFile').writeAsStringSync('');
    expect(removeDroppedFrameworks(work), isEmpty);
    expect(File('$app/$droppedFrameworksFile').existsSync(), isFalse);
  });

  test('fails without the list', () {
    expect(
      () => removeDroppedFrameworks(work),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('has no $droppedFrameworksFile'),
        ),
      ),
    );
  });

  test('refuses a name that is not a framework', () {
    File('$app/$droppedFrameworksFile').writeAsStringSync('../Info.plist\n');
    expect(() => removeDroppedFrameworks(work), throwsStateError);
  });
}
