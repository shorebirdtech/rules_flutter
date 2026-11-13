/// An app whose only plugin builds its own native library for Android.
library;

import 'package:flutter/widgets.dart';
import 'package:jni_probe/jni_probe.dart';

void main() =>
    runApp(const Text(jniProbeLibrary, textDirection: TextDirection.ltr));
