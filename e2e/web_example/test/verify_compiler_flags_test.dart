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

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  // Through the runfiles library, not `$TEST_SRCDIR` paths: `windows-latest`
  // runs with `--noenable_runfiles`, so there is no tree to walk there.
  final runfiles = Runfiles.create();
  String bundle(String path) => runfiles.rlocation('_main/$path');
  var failed = false;
  void check(String label, {required bool ok, required String detail}) {
    if (ok) {
      print('$label: OK ($detail)');
    } else {
      stderr.writeln('$label: FAIL — $detail');
      failed = true;
    }
  }

  File bundleFile(String target, String name) {
    final f = File('${bundle('${target}_web')}/$name');
    if (!f.existsSync()) {
      stderr.writeln('missing $name in $target bundle at ${f.path}');
      failed = true;
    }
    return f;
  }

  final tunedJs = bundleFile('app_tuned', 'main.dart.js');
  final defaultJs = bundleFile('app_wasm', 'main.dart.js');
  final tunedWasm = bundleFile('app_tuned', 'main.dart.wasm');
  final defaultWasm = bundleFile('app_wasm', 'main.dart.wasm');
  if (failed) exit(1);

  // `js_fallback = False` makes a bundle WebAssembly alone: no JavaScript
  // build, and no mention of one for the loader to go looking for.
  final wasmOnlyDir = Directory(bundle('app_wasm_only_web'));
  final wasmOnlyJs = wasmOnlyDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('main.dart.js'))
      .toList();
  check(
    'js_fallback = False ships no main.dart.js',
    ok: wasmOnlyJs.isEmpty,
    detail: wasmOnlyJs.isEmpty ? 'WebAssembly only' : 'shipped $wasmOnlyJs',
  );
  final wasmOnlyBootstrap = File(
    '${wasmOnlyDir.path}/flutter_bootstrap.js',
  ).readAsStringSync();
  check(
    'js_fallback = False lists only the WASM build',
    ok:
        wasmOnlyBootstrap.contains('"compileTarget":"dart2wasm"') &&
        !wasmOnlyBootstrap.contains('dart2js') &&
        !wasmOnlyBootstrap.contains('main.dart.js'),
    detail: 'no dart2js build and no main.dart.js in the build config',
  );

  // Which renderer files ship. The default loader fetches the renderer from
  // gstatic.com and never reads the bundle's own `canvaskit/`, so a bundle has
  // one only when it serves its own renderer (`use_local_canvaskit`).
  // flutter.js never falls from skwasm to CanvasKit or back, so that
  // directory holds the files of the renderers its builds use: skwasm alone
  // for `app_all_browsers`, both for `app_tuned` (WASM plus JS). The
  // `.symbols` maps are never fetched, so they ship nowhere.
  bool ships(String target, String file) =>
      File('${bundle('${target}_web')}/canvaskit/$file').existsSync();
  check(
    'app_wasm has no canvaskit/ directory',
    ok: !Directory('${bundle('app_wasm_web')}/canvaskit').existsSync(),
    detail: 'nothing would load it: the renderer comes from gstatic.com',
  );
  check(
    'app_wasm_only has no canvaskit/ directory either',
    ok: !Directory('${bundle('app_wasm_only_web')}/canvaskit').existsSync(),
    detail: 'leaving the JS build out does not change that',
  );
  check(
    'app_all_browsers ships skwasm and no CanvasKit',
    ok:
        ships('app_all_browsers', 'skwasm.wasm') &&
        ships('app_all_browsers', 'skwasm_heavy.wasm') &&
        !ships('app_all_browsers', 'canvaskit.wasm') &&
        !ships('app_all_browsers', 'chromium/canvaskit.wasm'),
    detail: 'skwasm.wasm and skwasm_heavy.wasm present, canvaskit.wasm absent',
  );
  check(
    'app_tuned ships both renderers',
    ok:
        ships('app_tuned', 'skwasm.wasm') &&
        ships('app_tuned', 'chromium/canvaskit.wasm'),
    detail: 'its JS build renders with CanvasKit, its WASM build with skwasm',
  );
  final symbolMaps = [
    for (final target in ['app_all_browsers', 'app_tuned'])
      ...Directory('${bundle('${target}_web')}/canvaskit')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.symbols')),
  ];
  check(
    'no .symbols map ships in a bundle',
    ok: symbolMaps.isEmpty,
    detail: symbolMaps.isEmpty ? 'none shipped' : 'shipped $symbolMaps',
  );

  // `wasm_browsers` reaches the page's loader call as an exact allow-list, and
  // a bundle that does not set it carries none (Flutter's default applies).
  final allBrowsers = File(
    '${bundle('app_all_browsers_web')}/flutter_bootstrap.js',
  ).readAsStringSync();
  check(
    'wasm_browsers allows every engine named',
    ok: allBrowsers.contains(
      'wasmAllowList: '
      '{"blink":true,"gecko":true,"unknown":false,"webkit":true}',
    ),
    detail: 'allow-list in the loader call',
  );
  final noBlink = File(
    '${bundle('app_no_blink_web')}/flutter_bootstrap.js',
  ).readAsStringSync();
  check(
    'wasm_browsers leaves out the engine it does not name',
    ok: noBlink.contains(
      'wasmAllowList: '
      '{"blink":false,"gecko":true,"unknown":false,"webkit":true}',
    ),
    detail: 'blink refused',
  );
  check(
    'the default bootstrap sets no allow-list',
    ok: !wasmOnlyBootstrap.contains('wasmAllowList'),
    detail: 'Flutter default',
  );

  // The page shows a message, not a blank page, when the loader cannot start
  // the app.
  check(
    'a WASM-only bootstrap shows a message when no build can run',
    ok:
        wasmOnlyBootstrap.contains('.catch(function(error)') &&
        wasmOnlyBootstrap.contains('WebAssembly only'),
    detail: 'catch on `load` appends an alert to the page',
  );

  // By default the JavaScript build is there, listed after the WASM one so the
  // loader prefers WASM, and the message does not claim the app is WASM-only.
  final fallbackBootstrap = File(
    '${bundle('app_wasm_web')}/flutter_bootstrap.js',
  ).readAsStringSync();
  check(
    'a bundle with a JS build does not call itself WASM-only',
    ok:
        fallbackBootstrap.contains('.catch(function(error)') &&
        !fallbackBootstrap.contains('WebAssembly only'),
    detail: 'generic message',
  );
  final wasmAt = fallbackBootstrap.indexOf('"compileTarget":"dart2wasm"');
  final jsAt = fallbackBootstrap.indexOf('"compileTarget":"dart2js"');
  check(
    'the default lists the JS build after the WASM one',
    ok: wasmAt >= 0 && jsAt > wasmAt,
    detail: 'dart2wasm at $wasmAt, dart2js at $jsAt',
  );

  // minify_js = "false" — the Dart names survive into the JavaScript. Checked
  // by name rather than by size alone: a size difference could come from any
  // of the other settings, but an identifier only survives minification being
  // off.
  final tunedJsText = tunedJs.readAsStringSync();
  final defaultJsText = defaultJs.readAsStringSync();
  for (final identifier in ['StatelessWidget', 'MyHomePage']) {
    check(
      'minify_js=false keeps `$identifier`',
      ok: tunedJsText.contains(identifier),
      detail: 'present in the unminified build',
    );
    check(
      'the default fallback build minifies `$identifier` away',
      ok: !defaultJsText.contains(identifier),
      detail: 'absent from the minified fallback build, as it should be',
    );
  }

  // strip_wasm = False + minify_wasm = "false" — the WASM keeps what the
  // default build discards, so it is materially larger.
  final tunedWasmLen = tunedWasm.lengthSync();
  final defaultWasmLen = defaultWasm.lengthSync();
  check(
    'strip_wasm=False/minify_wasm=false keep WASM symbols',
    ok: tunedWasmLen > defaultWasmLen,
    detail: 'tuned $tunedWasmLen bytes > default $defaultWasmLen bytes',
  );

  // dump_info = True — the report is a named build output, NOT something
  // every visitor downloads. `flutter build web` writes it into the deployed
  // directory; this rule deliberately does not, and the file runs to tens of
  // megabytes for this app, so the difference is not academic.
  final strays = Directory(bundle('app_tuned_web'))
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.info.json'))
      .toList();
  check(
    'dump_info stays out of the deployed bundle',
    ok: strays.isEmpty,
    detail: strays.isEmpty
        ? 'no .info.json shipped'
        : 'shipped ${strays.length}: $strays',
  );

  // The compile debris dart2js writes beside its output must not ship either.
  final deps = Directory(bundle('app_tuned_web'))
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.deps'))
      .toList();
  check(
    'dart2js .deps stays out of the deployed bundle',
    ok: deps.isEmpty,
    detail: deps.isEmpty ? 'no .deps shipped' : 'shipped ${deps.length}: $deps',
  );

  // `use_local_canvaskit` is the difference between an app that renders under
  // a strict `script-src 'self'` and one that does not: without it the engine
  // fetches CanvasKit from gstatic.com, and the policy blocks it. Both bundles
  // ship a local `canvaskit/` either way, so file presence proves nothing —
  // `useLocalCanvasKit` in the build config is the flag the loader actually
  // reads, which makes it the thing worth asserting.
  final tunedConfig = File('${bundle('app_tuned_web')}/flutter_bootstrap.js')
      .readAsStringSync();
  check(
    'app_tuned declares useLocalCanvasKit',
    ok: tunedConfig.contains('"useLocalCanvasKit":true'),
    detail: tunedConfig.contains('"useLocalCanvasKit":true')
        ? 'renderer loads from the app origin'
        : 'absent — the engine would fetch CanvasKit from gstatic.com, '
              "which `script-src 'self'` blocks",
  );

  // The negative half: a target that does not ask for it must not get it, or
  // the assertion above would pass for every build and prove nothing.
  final jsConfig = File('${bundle('app_js_web')}/flutter_bootstrap.js')
      .readAsStringSync();
  check(
    'app_js leaves useLocalCanvasKit unset',
    ok: !jsConfig.contains('useLocalCanvasKit'),
    detail: !jsConfig.contains('useLocalCanvasKit')
        ? 'absent as declared'
        : 'present without the attribute being set',
  );

  if (failed) exit(1);
  print('');
  print('All web compiler-flag checks passed.');
}
