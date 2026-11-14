// The files a library's `data` names, and those of the libraries under it,
// are in the runfiles of a `flutter_test` that reaches it, as they are for a
// `dart_test`.
import 'dart:io';

import 'package:data_dep/data_dep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();

  test("a flutter_library's data is in the runfiles", () {
    expect(
      File(runfiles.rlocation(flutterFixture)).readAsStringSync().trim(),
      'from the flutter_library',
    );
  });

  test("a dart_library's data under it is in the runfiles", () {
    expect(
      File(runfiles.rlocation(innerFixture)).readAsStringSync().trim(),
      'from the dart_library',
    );
  });
}
