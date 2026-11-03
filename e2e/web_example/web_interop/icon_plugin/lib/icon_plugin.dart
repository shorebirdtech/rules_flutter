/// A web plugin that holds an icon of its own: the registrant calls
/// [IconPlugin.registerWith], and nothing else imports this library.
library;

import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// The plugin class `flutter.plugin.platforms.web.pluginClass` names.
class IconPlugin {
  /// The icon the plugin registered with.
  static IconData? shown;

  /// Called by the generated plugin registrant at startup.
  static void registerWith(Object? registrar) {
    shown = Icons.bolt;
    web.document.title = 'icon_plugin ${'registered'.toJS.toDart}';
  }
}
