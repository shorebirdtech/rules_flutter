import 'package:flutter/services.dart';

/// The text of the plugin's bundled resource, as its Swift code reads it.
Future<String?> resourcePluginGreeting() =>
    const MethodChannel('resource_plugin').invokeMethod<String>('greeting');
