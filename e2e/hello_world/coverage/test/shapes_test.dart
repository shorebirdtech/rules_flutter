import 'package:flutter_test/flutter_test.dart';
import 'package:shapes/shapes.dart';

void main() {
  test('a square of side 2 m has an area of 4 m²', () {
    expect(squareArea(2, 'm'), '4 m²');
  });
}
