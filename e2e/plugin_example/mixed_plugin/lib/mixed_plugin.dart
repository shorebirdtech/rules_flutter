/// A plugin whose Apple code mixes Objective-C and Swift in one module.
library;

import 'package:flutter/services.dart';

/// The plugin's channel.
class MixedPlugin {
  static const _channel = MethodChannel('mixed_plugin');

  /// The greeting the native side answers with.
  static Future<String?> greeting() =>
      _channel.invokeMethod<String>('greeting');
}
