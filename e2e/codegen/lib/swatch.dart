/// A library with `dart:ui` fields, the input of `ui_type_generator`.
///
/// Flutter re-exports these types from `dart:ui`, which a generator resolves
/// only when the analysis its action runs has Flutter's `sky_engine`.
library;

import 'package:flutter/widgets.dart';

part 'swatch.g.dart';

/// A colored rectangle.
class Swatch {
  /// Creates a swatch.
  const Swatch(this.color, this.origin, this.extent);

  /// The fill.
  final Color color;

  /// The top left corner.
  final Offset origin;

  /// The width and height.
  final Size extent;
}
