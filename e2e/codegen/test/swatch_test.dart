/// Exercises: a generator run over a Flutter library resolving `dart:ui`.
///
/// `lib/swatch.dart`'s fields are `Color`, `Offset` and `Size`, which Flutter
/// takes from `dart:ui`. `:swatch_gen` runs `ui_type_generator` over it and
/// fails the build when a type does not resolve; this checks what it resolved.
library;

import 'package:codegen_e2e/swatch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('field types resolve to their dart:ui elements', () {
    expect(resolvedFieldTypes, {
      'Swatch.color': 'Color from dart:ui',
      'Swatch.origin': 'Offset from dart:ui',
      'Swatch.extent': 'Size from dart:ui',
    });
  });
}
