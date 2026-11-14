import 'package:flutter/widgets.dart';
import 'package:int64_ids/ids.dart';

/// Shows the largest identifier its compiler can hold.
///
/// `package:int64_ids` is two libraries (`ids_typed`, `ids_js`) with one
/// package name, and `:ids` picks one by the web compiler: the `Int64List`
/// under dart2wasm, a `List<int>` under dart2js and DDC. This file is the same
/// for both.
void main() {
  final ids = makeIds();
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('$idsType max: ${ids[0]}')),
    ),
  );
}
