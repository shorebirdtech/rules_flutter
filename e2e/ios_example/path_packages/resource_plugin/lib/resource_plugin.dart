import 'package:flutter/services.dart';

/// The text of the plugin's bundled resource, as its Swift code reads it.
Future<String?> resourcePluginGreeting() =>
    const MethodChannel('resource_plugin').invokeMethod<String>('greeting');

/// The text of the resource of the plugin's Objective-C target, which that
/// target reads through `SWIFTPM_MODULE_BUNDLE`.
Future<String?> resourcePluginObjcGreeting() =>
    const MethodChannel('resource_plugin').invokeMethod<String>('greetingObjc');
