import 'package:flutter/widgets.dart';
import 'package:flutter_qjs_next/flutter_qjs.dart';

/// Shows what QuickJS, compiled into the app from flutter_qjs_next's Swift
/// package, makes of `6 * 7`: `42` when the plugin's C code is in the app.
void main() {
  final result = getJavascriptRuntime().evaluate('6 * 7');
  runApp(
    Center(
      child: Text(
        'quickjs: ${result.stringResult}',
        textDirection: TextDirection.ltr,
      ),
    ),
  );
}
