/// Verifies the web compiler settings reach the shipped bundle, by reading the
/// bundle rather than the command line.
///
/// The analysis tests in `flutter/tests/web_test.bzl` pin the flags onto the
/// dart2js and dart2wasm argv. That proves what was asked for, not what came
/// out — a flag can be spelled correctly, accepted by the compiler, and still
/// change nothing. So this compares builds of the SAME app:
///
///   app_wasm:      the defaults: stripped, minified WASM with minified JS
///                  beside it, in the default (release) configuration.
///   app_wasm_only: the same with `js_fallback = False`: WebAssembly alone.
///   app_tuned:     minify_js/minify_wasm off and strip_wasm off, plus
///                  dump_info.
///
/// Every assertion below is a difference between those two bundles, so it
/// fails if the attrs stop being honoured — which asserting on one bundle
/// alone would not.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/web_bundle.dart';

void main() {
  final check = BundleCheck();
  final tuned = WebBundle.fromRunfiles(
    'app_tuned_web',
    check,
    label: 'app_tuned',
  );
  final defaults = WebBundle.fromRunfiles(
    'app_wasm_web',
    check,
    label: 'app_wasm',
  );
  final js = WebBundle.fromRunfiles('app_js_web', check, label: 'app_js');

  final tunedJs = tuned.requireFile('main.dart.js');
  final defaultJs = defaults.requireFile('main.dart.js');
  final tunedWasm = tuned.requireFile('main.dart.wasm');
  final defaultWasm = defaults.requireFile('main.dart.wasm');
  if (tunedJs == null ||
      defaultJs == null ||
      tunedWasm == null ||
      defaultWasm == null) {
    exit(1); // each missing file is already recorded as a failure
  }

  final wasmOnly = WebBundle.fromRunfiles(
    'app_wasm_only_web',
    check,
    label: 'app_wasm_only',
  );
  final allBrowsers = WebBundle.fromRunfiles(
    'app_all_browsers_web',
    check,
    label: 'app_all_browsers',
  );
  final noBlink = WebBundle.fromRunfiles(
    'app_no_blink_web',
    check,
    label: 'app_no_blink',
  );

  // `js_fallback = False` makes a bundle WebAssembly alone: no JavaScript
  // build, and no mention of one for the loader to go looking for.
  final wasmOnlyJs = wasmOnly.filesEndingWith('main.dart.js');
  check.expect(
    'js_fallback = False ships no main.dart.js',
    condition: wasmOnlyJs.isEmpty,
    detail: 'shipped $wasmOnlyJs',
  );
  final wasmOnlyBootstrap = wasmOnly.read('flutter_bootstrap.js') ?? '';
  check.expect(
    'js_fallback = False lists only the WASM build',
    condition:
        wasmOnlyBootstrap.contains('"compileTarget":"dart2wasm"') &&
        !wasmOnlyBootstrap.contains('dart2js') &&
        !wasmOnlyBootstrap.contains('main.dart.js'),
    detail: 'the build config names a dart2js build or main.dart.js',
  );

  // Which renderer files ship. The default loader fetches the renderer from
  // gstatic.com and never reads the bundle's own `canvaskit/`, so a bundle has
  // one only when it serves its own renderer (`use_local_canvaskit`).
  // flutter.js never falls from skwasm to CanvasKit or back, so that
  // directory holds the files of the renderers its builds use: skwasm alone
  // for `app_all_browsers`, both for `app_tuned` (WASM plus JS). The
  // `.symbols` maps are never fetched, so they ship nowhere.
  bool ships(WebBundle bundle, String file) =>
      bundle.file('canvaskit/$file').existsSync();
  check
    ..expect(
      'app_wasm has no canvaskit/ directory',
      condition: !Directory('${defaults.path}/canvaskit').existsSync(),
      detail: 'nothing would load it: the renderer comes from gstatic.com',
    )
    ..expect(
      'app_wasm_only has no canvaskit/ directory either',
      condition: !Directory('${wasmOnly.path}/canvaskit').existsSync(),
      detail: 'leaving the JS build out does not change that',
    )
    ..expect(
      'app_all_browsers ships skwasm and no CanvasKit',
      condition:
          ships(allBrowsers, 'skwasm.wasm') &&
          ships(allBrowsers, 'skwasm_heavy.wasm') &&
          !ships(allBrowsers, 'canvaskit.wasm') &&
          !ships(allBrowsers, 'chromium/canvaskit.wasm'),
      detail: 'want skwasm.wasm and skwasm_heavy.wasm, and no canvaskit.wasm',
    )
    ..expect(
      'app_tuned ships both renderers',
      condition:
          ships(tuned, 'skwasm.wasm') &&
          ships(tuned, 'chromium/canvaskit.wasm'),
      detail: 'its JS build renders with CanvasKit, its WASM build with skwasm',
    );
  final symbolMaps = [
    for (final bundle in [allBrowsers, tuned])
      ...Directory('${bundle.path}/canvaskit')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.symbols')),
  ];
  check.expect(
    'no .symbols map ships in a bundle',
    condition: symbolMaps.isEmpty,
    detail: 'shipped $symbolMaps',
  );

  // `wasm_browsers` reaches the page's loader call as an exact allow-list, and
  // a bundle that does not set it carries none (Flutter's default applies).
  final allBrowsersBootstrap = allBrowsers.read('flutter_bootstrap.js') ?? '';
  check.expect(
    'wasm_browsers allows every engine named',
    condition: allBrowsersBootstrap.contains(
      'wasmAllowList: '
      '{"blink":true,"gecko":true,"unknown":false,"webkit":true}',
    ),
    detail: 'allow-list missing from the loader call',
  );
  final noBlinkBootstrap = noBlink.read('flutter_bootstrap.js') ?? '';
  check
    ..expect(
      'wasm_browsers leaves out the engine it does not name',
      condition: noBlinkBootstrap.contains(
        'wasmAllowList: '
        '{"blink":false,"gecko":true,"unknown":false,"webkit":true}',
      ),
      detail: 'blink not refused',
    )
    ..expect(
      'the default bootstrap sets no allow-list',
      condition: !wasmOnlyBootstrap.contains('wasmAllowList'),
      detail: 'Flutter default should apply',
    )
    // The page shows a message, not a blank page, when the loader cannot start
    // the app.
    ..expect(
      'a WASM-only bootstrap shows a message when no build can run',
      condition:
          wasmOnlyBootstrap.contains('.catch(function(error)') &&
          wasmOnlyBootstrap.contains('WebAssembly only'),
      detail: 'no catch on `load` that appends an alert to the page',
    );

  // By default the JavaScript build is there, listed after the WASM one so the
  // loader prefers WASM, and the message does not claim the app is WASM-only.
  final fallbackBootstrap = defaults.read('flutter_bootstrap.js') ?? '';
  check.expect(
    'a bundle with a JS build does not call itself WASM-only',
    condition:
        fallbackBootstrap.contains('.catch(function(error)') &&
        !fallbackBootstrap.contains('WebAssembly only'),
    detail: 'want the generic message',
  );
  final wasmAt = fallbackBootstrap.indexOf('"compileTarget":"dart2wasm"');
  final jsAt = fallbackBootstrap.indexOf('"compileTarget":"dart2js"');
  check.expect(
    'the default lists the JS build after the WASM one',
    condition: wasmAt >= 0 && jsAt > wasmAt,
    detail: 'dart2wasm at $wasmAt, dart2js at $jsAt',
  );

  // minify_js = "false" — the Dart names survive into the JavaScript. Checked
  // by name rather than by size alone: a size difference could come from any
  // of the other settings, but an identifier only survives minification being
  // off.
  final tunedJsText = tunedJs.readAsStringSync();
  final defaultJsText = defaultJs.readAsStringSync();
  for (final identifier in ['StatelessWidget', 'MyHomePage']) {
    check
      ..expect(
        'minify_js=false keeps `$identifier`',
        condition: tunedJsText.contains(identifier),
        detail: 'absent from the unminified build',
      )
      ..expect(
        'the default fallback build minifies `$identifier` away',
        condition: !defaultJsText.contains(identifier),
        detail: 'present in the minified fallback build',
      );
  }

  // strip_wasm = False + minify_wasm = "false" — the WASM keeps what the
  // default build discards, so it is materially larger.
  final tunedWasmLen = tunedWasm.lengthSync();
  final defaultWasmLen = defaultWasm.lengthSync();
  check.expect(
    'strip_wasm=False/minify_wasm=false keep WASM symbols '
    '(tuned $tunedWasmLen bytes > default $defaultWasmLen bytes)',
    condition: tunedWasmLen > defaultWasmLen,
    detail: 'tuned $tunedWasmLen bytes <= default $defaultWasmLen bytes',
  );

  // dump_info = True — the report is a named build output, NOT something
  // every visitor downloads. `flutter build web` writes it into the deployed
  // directory; this rule deliberately does not, and the file runs to tens of
  // megabytes for this app, so the difference is not academic.
  final strays = tuned.filesEndingWith('.info.json');
  check.expect(
    'dump_info stays out of the deployed bundle',
    condition: strays.isEmpty,
    detail: 'shipped ${strays.length}: $strays',
  );

  // The compile debris dart2js writes beside its output must not ship either.
  final deps = tuned.filesEndingWith('.deps');
  check.expect(
    'dart2js .deps stays out of the deployed bundle',
    condition: deps.isEmpty,
    detail: 'shipped ${deps.length}: $deps',
  );

  // `use_local_canvaskit` is the difference between an app that renders under
  // a strict `script-src 'self'` and one that does not: without it the engine
  // fetches CanvasKit from gstatic.com, and the policy blocks it. Both bundles
  // ship a local `canvaskit/` either way, so file presence proves nothing —
  // `useLocalCanvasKit` in the build config is the flag the loader actually
  // reads, which makes it the thing worth asserting.
  final tunedConfig = tuned.read('flutter_bootstrap.js') ?? '';
  check.expect(
    'app_tuned declares useLocalCanvasKit',
    condition: tunedConfig.contains('"useLocalCanvasKit":true'),
    detail:
        'absent — the engine would fetch CanvasKit from gstatic.com, '
        "which `script-src 'self'` blocks",
  );

  // The negative half: a target that does not ask for it must not get it, or
  // the assertion above would pass for every build and prove nothing.
  final jsConfig = js.read('flutter_bootstrap.js') ?? '';
  check
    ..expect(
      'app_js leaves useLocalCanvasKit unset',
      condition: !jsConfig.contains('useLocalCanvasKit'),
      detail: 'present without the attribute being set',
    )
    ..finish('All web compiler-flag checks passed.');
}
