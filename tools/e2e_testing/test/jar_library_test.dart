import 'package:rules_flutter_e2e_testing/jar_library.dart';
import 'package:rules_flutter_e2e_testing/zip_entries.dart';
import 'package:test/test.dart';

ZipEntry _entry(String name, int crc32) =>
    ZipEntry(name, method: 8, dataOffset: 0, crc32: crc32);

void main() {
  final library = [
    _entry('kotlin/KotlinVersion.class', 1),
    _entry('kotlin/collections/ArraysKt.class', 2),
    _entry('META-INF/versions/9/module-info.class', 3),
  ];

  test('an app with exactly the library has nothing foreign', () {
    expect(
      classesNotFrom([
        ...library,
        _entry('com/example/MainActivity.class', 9),
      ], library),
      isEmpty,
    );
  });

  test('names a class another version defines differently', () {
    expect(
      classesNotFrom([
        _entry('kotlin/KotlinVersion.class', 7),
        _entry('kotlin/collections/ArraysKt.class', 2),
      ], library),
      ['kotlin/KotlinVersion.class'],
    );
  });

  test("names a class only another version has, in the library's package", () {
    expect(
      classesNotFrom([
        ...library,
        _entry('kotlin/ContextParametersKt.class', 4),
      ], library),
      ['kotlin/ContextParametersKt.class'],
    );
  });

  test('leaves other packages and META-INF alone', () {
    expect(
      classesNotFrom([
        ...library,
        _entry('kotlin/reflect/full/KClasses.class', 5),
        _entry('META-INF/versions/9/module-info.class', 6),
      ], library),
      isEmpty,
    );
  });
}
