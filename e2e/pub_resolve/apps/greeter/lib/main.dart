import 'package:flutter/material.dart';
import 'package:greeting/greeting.dart';

void main() {
  runApp(const GreeterApp());
}

/// Shows the greeting once it has loaded.
class GreeterApp extends StatelessWidget {
  /// Creates the app.
  const GreeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Greeter',
      home: Scaffold(
        body: Center(
          child: FutureBuilder<String>(
            future: Greeting.text(),
            builder: (context, snapshot) {
              final text = snapshot.data;
              if (text == null) {
                return const CircularProgressIndicator();
              }
              return Text(text, key: const ValueKey('greeting'));
            },
          ),
        ),
      ),
    );
  }
}
