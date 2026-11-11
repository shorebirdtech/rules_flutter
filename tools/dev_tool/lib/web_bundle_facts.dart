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

import 'dev_tool_exception.dart';

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

/// The run's target built, and none of its outputs is a web bundle: it is not a
/// `flutter_web_bundle` (or a `flutter_web_app`, which makes one), typically
/// the `flutter_application` a web target is built over.
class NotAWebBundle extends DevToolException {
  NotAWebBundle()
    : super(
        'The target is not a web bundle: its build has no `_web` directory.',
      );
}

/// The rule class of the staging target `flutter_web_bundle` declares beside a
/// bundle. It carries the `application` the bundle is built over, and names the
/// bundle in its `bundle` attribute.
const webBranchRuleClass = 'flutter_web_branch';

/// The `query` arguments that list the web bundles built over the application
/// [label] (canonical, as `bazel query <target> --output=label` prints it):
/// the branch targets whose `application` is it, each naming its bundle.
List<String> webBundlesOverQuery(String label) => [
  'query',
  'attr(application, "^(@@)?${RegExp.escape(label)}\$", '
      'kind("$webBranchRuleClass", //...))',
  '--output=streamed_jsonproto',
  '--proto:output_rule_attrs=bundle',
  '--noshow_progress',
];

/// The bundle labels in the output of [webBundlesOverQuery], sorted.
///
/// Throws [FormatException] for output that is not what the query asks for.
List<String> parseWebBundlesOver(String streamedJsonproto) {
  final bundles = <String>{};
  for (final line in LineSplitter.split(streamedJsonproto)) {
    if (line.trim().isEmpty) continue;
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, Object?>) {
      throw FormatException('query printed no JSON object', line);
    }
    final rule = decoded['rule'];
    for (final attribute
        in (rule is Map<String, Object?> ? rule['attribute'] : null)
                as List<Object?>? ??
            const []) {
      final a = attribute as Map<String, Object?>;
      if (a['name'] != 'bundle') continue;
      // The main repository prints as `@@//pkg:name`.
      bundles.add((a['stringValue'] as String).replaceFirst('@@//', '//'));
    }
  }
  return bundles.toList()..sort();
}

/// What a run says for a [target] that is not a web bundle: [bundles] are the
/// web targets over it, or empty when there are none to name.
String notAWebBundleMessage(String target, List<String> bundles) {
  final what =
      '$target is not a web bundle: building it produced no `_web` '
      'directory, which is what a browser run serves.';
  if (bundles.isEmpty) {
    return '$what\n'
        'A web run takes a `flutter_web_app` or `flutter_web_bundle`. Make '
        'one over this target with `application = "$target"`, or look for '
        'a web target that names it as its `application`.';
  }
  return '$what\n'
      'Run a web target built over it instead:\n'
      '${bundles.map((b) => '  $b').join('\n')}';
}
