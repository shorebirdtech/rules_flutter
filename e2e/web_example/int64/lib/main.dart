import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// The largest signed 64-bit integer. dart2js cannot represent it ("can't be
/// represented exactly in JavaScript") and refuses to compile the literal;
/// dart2wasm holds it in a real 64-bit integer.
const maxInt64 = 0x7FFFFFFFFFFFFFFF;

/// Stores [maxInt64] in an [Int64List], which dart2js builds but throws on at
/// runtime ("not supported on the web"), and shows it back.
void main() {
  final ids = Int64List.fromList([maxInt64, 1 << 40]);
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('Int64List max: ${ids[0]}')),
    ),
  );
}
