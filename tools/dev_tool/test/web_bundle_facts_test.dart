/// [parseWebBundleFacts] — how a web run learns, before building, whether the
/// bundle it runs ships WebAssembly only.
library;

import 'package:flutter_bazel_dev_tool/web_bundle_facts.dart';
import 'package:test/test.dart';

/// `cquery --output=jsonproto` for [webBundleFactsQuery] over a bundle,
/// trimmed to the fields the parser reads, as bazel 9 prints them.
String answer({
  String ruleClass = 'flutter_web_bundle',
  String name = '//app:web',
  bool? jsFallback,
}) =>
    '''
{
  "target": [{
    "type": "RULE",
    "rule": {
      "name": "$name",
      "ruleClass": "$ruleClass",
      "attribute": [${jsFallback == null ? '' : '''{
        "name": "js_fallback",
        "type": "BOOLEAN",
        "intValue": ${jsFallback ? 1 : 0},
        "stringValue": "$jsFallback",
        "explicitlySpecified": ${!jsFallback},
        "booleanValue": $jsFallback
      }, '''}{
        "name": "\$rule_implementation_hash",
        "type": "STRING",
        "stringValue": "11a5c1"
      }]
    }
  }]
}
''';

void main() {
  group('parseWebBundleFacts', () {
    test('js_fallback = False is a WebAssembly-only bundle', () {
      expect(parseWebBundleFacts(answer(jsFallback: false))!.wasmOnly, isTrue);
    });

    test('js_fallback = True, the default, is not', () {
      expect(parseWebBundleFacts(answer(jsFallback: true))!.wasmOnly, isFalse);
    });

    test('no bundle in the answer leaves nothing to decide by', () {
      expect(parseWebBundleFacts('{}'), isNull);
      expect(parseWebBundleFacts(''), isNull);
      expect(
        parseWebBundleFacts(answer(ruleClass: 'alias', jsFallback: false)),
        isNull,
      );
    });

    test('a bundle that does not report js_fallback is a loud failure', () {
      expect(
        () => parseWebBundleFacts(answer()),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('//app:web reports no js_fallback'),
          ),
        ),
      );
    });

    test('two bundles cannot speak for one target', () {
      final two = answer(jsFallback: false).replaceFirst(
        '}]\n}',
        '}, {"type": "RULE", "rule": {"name": "//app:b", '
            '"ruleClass": "flutter_web_bundle", "attribute": []}}]\n}',
      );
      expect(parseWebBundleFacts(two), isNull);
    });
  });

  test('the query asks for the bundle behind an alias, with defaults', () {
    final args = webBundleFactsQuery('//app:web');
    expect(args.first, 'cquery');
    expect(args[1], 'kind("flutter_web_bundle", deps(//app:web, 1))');
    expect(args, contains('--proto:output_rule_attrs=js_fallback'));
  });
}
