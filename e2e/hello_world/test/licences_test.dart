// The licences a build bundles: the engine's, the framework's and those of the
// pub packages the program depends on. The test binding registers no licences
// with the framework, so this reads the `NOTICES.Z` asset it would read.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('NOTICES.Z names the packages the program uses', (tester) async {
    final text = await tester.runAsync(() async {
      final bytes = (await rootBundle.load('NOTICES.Z')).buffer.asUint8List();
      return utf8.decode(gzip.decode(bytes));
    });

    // Each entry names its packages on the lines before its first blank one,
    // as the framework reads them.
    final names = <String>{
      for (final entry in text!.split('\n${'-' * 80}\n'))
        if (entry.contains('\n\n')) ...entry.split('\n\n').first.split('\n'),
    };

    expect(
      names,
      contains('flutter'),
      reason: 'the LICENSE of package:flutter',
    );
    expect(names, contains('skia'), reason: 'the licences of the engine');
    expect(
      names,
      contains('cupertino_icons'),
      reason: 'a pub package the app depends on',
    );
    expect(
      names,
      contains('flutter_localized_locales'),
      reason: 'a pub package the app depends on',
    );
  });
}
