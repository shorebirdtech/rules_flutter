import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/plist.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';
import 'package:test/test.dart';

/// `plutil` reads the plists, and only macOS has it.
final _noPlutil = Platform.isMacOS ? null : 'needs plutil';

const _sandboxed =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<plist version="1.0"><dict>'
    '<key>com.apple.security.app-sandbox</key><true/>'
    '<key>com.apple.security.application-groups</key>'
    '<array><string>group.example</string></array>'
    '</dict></plist>';

void main() {
  group('CodeSignature.parseTeamIdentifier', () {
    test('reads the team of a team-signed bundle', () {
      const report =
          'Identifier=com.example.app\n'
          'Format=app bundle with Mach-O thin (arm64)\n'
          'TeamIdentifier=ABCDE12345\n'
          'Sealed Resources version=2 rules=13 files=40\n';
      expect(CodeSignature.parseTeamIdentifier(report), 'ABCDE12345');
    });

    test('is null for an ad hoc signature', () {
      const report = 'Signature=adhoc\nTeamIdentifier=not set\n';
      expect(CodeSignature.parseTeamIdentifier(report), isNull);
    });

    test('is null when the report names no team', () {
      expect(CodeSignature.parseTeamIdentifier('Identifier=x\n'), isNull);
    });
  });

  group('Entitlements', () {
    late StringBuffer err;
    late BundleCheck check;

    setUp(() {
      err = StringBuffer();
      check = BundleCheck(out: StringBuffer(), err: err, exit: (_) {});
    });

    test('an empty blob declares nothing', () {
      final entitlements = Entitlements.parse('\n');
      expect(entitlements.declares('com.apple.security.app-sandbox'), isFalse);
      expect(entitlements.applicationGroups, isNull);
    });

    test('reads keys and flags from an XML plist', () {
      final entitlements = Entitlements.parse(_sandboxed);
      expect(entitlements.declares('com.apple.security.app-sandbox'), isTrue);
      expect(entitlements.isEnabled('com.apple.security.app-sandbox'), isTrue);
      expect(
        entitlements.declares('com.apple.security.network.client'),
        isFalse,
      );
      expect(entitlements.applicationGroups, ['group.example']);
    }, skip: _noPlutil);

    test('checkInGroup passes for a listed group and fails for another', () {
      Entitlements.parse(_sandboxed)
        ..checkInGroup(check, 'app', 'group.example')
        ..checkInGroup(check, 'app', 'group.other');
      expect(check.failures, hasLength(1));
      expect(
        err.toString(),
        contains('app has App Groups [group.example], expected group.other'),
      );
    }, skip: _noPlutil);
  });

  group('Plist', () {
    test('reads nested dictionaries', () {
      final plist = Plist.parseXml(
        '<plist version="1.0"><dict><key>NSExtension</key><dict>'
        '<key>NSExtensionPointIdentifier</key><string>point</string>'
        '</dict></dict></plist>',
      );
      expect(
        plist.dictionary('NSExtension')?['NSExtensionPointIdentifier'],
        'point',
      );
      expect(plist.dictionary('missing'), isNull);
    }, skip: _noPlutil);

    test('refuses text that is not a plist', () {
      expect(() => Plist.parseXml('nope'), throwsA(isA<ProcessException>()));
    }, skip: _noPlutil);
  });
}
