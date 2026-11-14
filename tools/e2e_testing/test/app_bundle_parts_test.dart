import 'dart:io';

import 'package:rules_flutter_e2e_testing/app_extensions.dart';
import 'package:rules_flutter_e2e_testing/app_intents.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StringBuffer out;
  late StringBuffer err;
  late BundleCheck check;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app_bundle_parts_test');
    out = StringBuffer();
    err = StringBuffer();
    check = BundleCheck(out: out, err: err, exit: (_) {});
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void makeDir(String relative) =>
      Directory('${tmp.path}/$relative').createSync(recursive: true);

  group('EmbeddedExtensions.checkEmbedded', () {
    final expected = {
      'share.appex': 'com.apple.share-services',
      'widgets.appex': 'com.apple.widgetkit-extension',
    };

    test('passes when PlugIns/ holds exactly the expected bundles', () {
      makeDir('PlugIns/share.appex');
      makeDir('PlugIns/widgets.appex');
      EmbeddedExtensions('${tmp.path}/PlugIns', expected).checkEmbedded(check);
      expect(check.ok, isTrue);
    });

    test('fails for a missing bundle, an extra one and no directory', () {
      makeDir('PlugIns/share.appex');
      EmbeddedExtensions('${tmp.path}/PlugIns', expected).checkEmbedded(check);
      expect(check.failures, hasLength(1));

      makeDir('PlugIns/widgets.appex');
      makeDir('PlugIns/stray.appex');
      EmbeddedExtensions('${tmp.path}/PlugIns', expected).checkEmbedded(check);
      expect(check.failures, hasLength(2));

      EmbeddedExtensions('${tmp.path}/None', expected).checkEmbedded(check);
      expect(check.failures, hasLength(3));
      expect(err.toString(), contains('does not exist'));
    });

    test('checkExtensionPoints fails for an extension with no Info.plist', () {
      makeDir('PlugIns/share.appex');
      EmbeddedExtensions('${tmp.path}/PlugIns', {
        'share.appex': 'com.apple.share-services',
      }).checkExtensionPoints(check, infoPlist: (appex) => '$appex/Info.plist');
      expect(check.failures.single, contains('share.appex has no Info.plist'));
    });
  });

  group('AppIntentsMetadata.checkNames', () {
    File write(String contents) =>
        File('${tmp.path}/Metadata.appintents/extract.actionsdata')
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);

    test('passes when the metadata names the intent', () {
      write('{"actions": ["PingIntent"]}');
      AppIntentsMetadata(tmp.path)
          .checkNames(check, 'PingIntent', owner: 'app');
      expect(check.ok, isTrue);
      expect(out.toString(), contains('app carries App Intents metadata'));
    });

    test('fails when the metadata names another intent', () {
      write('{"actions": ["OtherIntent"]}');
      AppIntentsMetadata(tmp.path)
          .checkNames(check, 'PingIntent', owner: 'app');
      expect(check.failures.single, contains('does not name PingIntent'));
    });

    test('fails when there is no metadata', () {
      AppIntentsMetadata(tmp.path)
          .checkNames(check, 'PingIntent', owner: 'app');
      expect(check.failures.single, contains('app has no extract.actionsdata'));
    });
  });
}
