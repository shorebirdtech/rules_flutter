import 'package:flutter/widgets.dart';

void main() {
  runApp(const CustomEngineApp());
}

/// Shows that the engine renders: a coloured screen with a line of text.
class CustomEngineApp extends StatelessWidget {
  /// Creates the app.
  const CustomEngineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF1B5E20),
      child: Center(
        child: Text(
          'Custom engine',
          textDirection: TextDirection.ltr,
          style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 40),
        ),
      ),
    );
  }
}
