/// Minimal Flutter test for build verification.
///
/// Verifies that dart:ui types are available at compilation time.
/// Avoids calling FFI-bound constructors since flutter_test runs on the
/// plain Dart VM without the Flutter engine shared library, and initializes no
/// Flutter binding.
library;

import 'dart:ui' show Color, Offset, Rect;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dart:ui types resolve and their non-native constructors work', () {
    const color = Color(0xFF00FF00);
    const rect = Rect.fromLTWH(0, 0, 100, 100);
    const offset = Offset(10, 20);

    expect(color.toARGB32(), 0xFF00FF00);
    expect(rect.width, 100);
    expect(offset.dx, 10);
  });
}
