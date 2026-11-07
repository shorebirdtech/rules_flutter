import 'package:flutter/services.dart';

/// The Swift language mode the plugin's Swift code was compiled in.
Future<String?> swift6PluginMode() =>
    const MethodChannel('swift6_plugin').invokeMethod<String>('mode');
