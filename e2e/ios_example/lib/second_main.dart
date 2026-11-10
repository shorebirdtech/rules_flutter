import 'package:flutter/widgets.dart';

/// The entry point of `:app_flutter_second`: a program of its own, so that its
/// App.framework is not the same construction as `:app_flutter`'s.
void main() {
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('Second app')),
    ),
  );
}
