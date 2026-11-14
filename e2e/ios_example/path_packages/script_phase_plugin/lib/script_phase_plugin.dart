import 'package:flutter/services.dart';

/// Asks the plugin's Swift code how it was built.
Future<String?> scriptPhasePluginBuild() =>
    const MethodChannel('script_phase_plugin').invokeMethod<String>('build');
