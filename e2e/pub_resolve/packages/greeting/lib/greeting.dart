import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:tagline/tagline.dart';

/// The greeting: text from this package's asset, a number formatted by a
/// package the lock lists as hosted (replaced by a fork in this workspace), and
/// the tagline of a path package.
class Greeting {
  const Greeting._();

  /// The greeting, `Hello from greeting — 1234 (forked intl) — tagline`.
  static Future<String> text() async {
    final greeting = await rootBundle.loadString(
      'packages/greeting/assets/greeting.txt',
    );
    final number = NumberFormat.decimalPattern('en_US').format(1234);
    return '${greeting.trim()} — $number — ${Tagline.text}';
  }
}
