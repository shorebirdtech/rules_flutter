import 'package:flutter/widgets.dart';
import 'package:pick/pick.dart';

/// An app that uses one of `package:pick`'s two operations. `pick`'s link hook
/// keeps that operation's native library and drops the other's, so a release
/// APK carries `libpick_kept.so` alone (`verify_android_pick_apk_test`).
void main() {
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Text('${const Op('kept').name}(20)=${pickKept(20)}'),
    ),
  );
}
