import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/web_bundle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late StringBuffer err;
  late BundleCheck check;
  late WebBundle bundle;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('web_bundle_test');
    File('${dir.path}/index.html').writeAsStringSync('<html>');
    Directory('${dir.path}/canvaskit').createSync();
    File('${dir.path}/canvaskit/a.info.json').writeAsStringSync('{}');
    File('${dir.path}/main.dart.js').writeAsStringSync('js');
    err = StringBuffer();
    check = BundleCheck(out: StringBuffer(), err: err, exit: (_) {});
    bundle = WebBundle(dir.path, check, label: 'app');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('read returns the text of a file that is there', () {
    expect(bundle.read('index.html'), '<html>');
    expect(check.ok, isTrue);
  });

  test('read fails the check, naming the bundle, for a missing file', () {
    expect(bundle.read('nope.js'), isNull);
    expect(check.failures, hasLength(1));
    expect(check.failures.single, startsWith('app: nope.js is missing'));
  });

  test('requireFile returns the file, or null after a failure', () {
    expect(bundle.requireFile('main.dart.js')!.lengthSync(), 2);
    expect(check.ok, isTrue);
    expect(bundle.requireFile('main.dart.wasm'), isNull);
    expect(check.ok, isFalse);
  });

  test('filesEndingWith looks in subdirectories', () {
    expect(
      bundle.filesEndingWith('.info.json').map((f) => f.path),
      [p.join(dir.path, 'canvaskit', 'a.info.json')],
    );
    expect(bundle.filesEndingWith('.deps'), isEmpty);
  });

  test('the label defaults to the directory name', () {
    final unnamed = WebBundle(dir.path, check);
    expect(unnamed.label, p.basename(dir.path));
  });
}
