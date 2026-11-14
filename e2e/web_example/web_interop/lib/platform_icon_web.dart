import 'dart:js_interop';

import 'package:flutter/material.dart';

/// The icon an app draws on the web.
const IconData platformIcon = Icons.language;

@JS('navigator.language')
external String? get _language;

/// The browser's language.
String? browserLanguage() => _language;
