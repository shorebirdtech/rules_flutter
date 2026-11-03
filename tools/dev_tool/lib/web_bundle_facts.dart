/// What the `flutter_web_bundle` behind a web run says about itself, read
/// before the run builds anything.
///
/// The dev loop a browser run uses depends on it: a bundle that ships
/// WebAssembly only must be developed under dart2wasm, because code that only
/// works there (an `Int64List`) breaks under the DDC (JavaScript) loop. The
/// build's outputs that describe a bundle (`<bundle>.serving.json`, the
/// `_dev_config.json`) exist only after the build, and the dev loop is chosen
/// before it, so the fact is read from the rule's attributes with `bazel
/// cquery` instead.
library;

import 'dart:convert';

/// The rule class a web bundle target is.
const webBundleRuleClass = 'flutter_web_bundle';

/// The attribute that makes a bundle WebAssembly only when false.
const jsFallbackAttribute = 'js_fallback';

/// The `cquery` arguments that list [target]'s web bundle with its
/// [jsFallbackAttribute], as JSON.
///
/// `deps(target, 1)` rather than the bare label so an `alias` to a bundle is
/// answered with the bundle it stands for; `kind` then keeps only bundles.
/// Defaults are included in the output, so a bundle that never mentions
/// `js_fallback` reports its default (true).
List<String> webBundleFactsQuery(String target) => [
  'cquery',
  'kind("$webBundleRuleClass", deps($target, 1))',
  '--output=jsonproto',
  '--proto:output_rule_attrs=$jsFallbackAttribute',
  '--proto:include_configurations=false',
  '--proto:rule_inputs_and_outputs=false',
  '--noshow_progress',
];

/// The facts about a web bundle that choose how it is developed.
class WebBundleFacts {
  /// Whether the bundle is WebAssembly only (`js_fallback = False`): it ships
  /// no JavaScript build, so nothing but dart2wasm ever compiles it.
  final bool wasmOnly;

  const WebBundleFacts({required this.wasmOnly});
}

/// The facts in [jsonproto], `cquery --output=jsonproto` output for
/// [webBundleFactsQuery], or null when the query found no single web bundle
/// to speak for the target (a wrapper rule that is not one, say), which leaves
/// nothing to choose a dev loop by.
///
/// Throws [FormatException] for output that is not what the query asks for.
WebBundleFacts? parseWebBundleFacts(String jsonproto) {
  if (jsonproto.trim().isEmpty) return null;
  final decoded = jsonDecode(jsonproto);
  if (decoded is! Map<String, Object?>) {
    throw FormatException('cquery printed no JSON object', jsonproto);
  }
  final bundles = <Map<String, Object?>>[];
  for (final entry in (decoded['target'] as List<Object?>?) ?? const []) {
    final rule = (entry as Map<String, Object?>)['rule'];
    if (rule is Map<String, Object?> &&
        rule['ruleClass'] == webBundleRuleClass) {
      bundles.add(rule);
    }
  }
  if (bundles.length != 1) return null;
  for (final attribute
      in (bundles.single['attribute'] as List<Object?>?) ?? const []) {
    final a = attribute as Map<String, Object?>;
    if (a['name'] != jsFallbackAttribute) continue;
    final value = a['booleanValue'];
    if (value is! bool) {
      throw FormatException('$jsFallbackAttribute is not a boolean', jsonproto);
    }
    return WebBundleFacts(wasmOnly: !value);
  }
  throw FormatException(
    '${bundles.single['name']} reports no $jsFallbackAttribute attribute',
    jsonproto,
  );
}
