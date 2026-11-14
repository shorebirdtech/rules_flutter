import 'package:units/units.dart';

/// The area of a square of side [side], in [unit] squared.
String squareArea(int side, String unit) {
  final area = side * side; // covered
  return '$area ${squared(unit)}'; // covered
}

/// The area of a rectangle, which the test never asks for.
String rectangleArea(int width, int height, String unit) {
  final area = width * height; // uncovered
  return '$area ${squared(unit)}'; // uncovered
}
