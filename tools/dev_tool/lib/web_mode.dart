/// Which kind of web run this is, decided once, at plan time.
///
/// A web run comes in exactly three shapes, and everything about the run —
/// which server fronts the browser, whether there is a VM service, what an
/// edit turns into — follows from which one it is. Re-deriving that decision at
/// each site from the raw flags (`isWebDevice`, `--wasm`, `--profile`,
/// `--hot`) combines them slightly differently each time: one gate ignores
/// `--profile` where another refuses it, and `--wasm` on a native device is
/// silently dropped.
///
/// [selectWasm] and [resolveWebMode] are the one place the flags are read.
/// Every other site switches on the result, and the sealed hierarchy is what makes the compiler
/// point at any site that forgot a shape.
library;

import 'dev_tool_exception.dart';

/// One of the three shapes a web run can take. `null` stands for "not a web
/// run at all" — [resolveWebMode] returns `WebMode?`, and a `switch` over it
/// is exhaustive over all four states.
sealed class WebMode {
  const WebMode();
}

/// The DDC dev loop: the module server fronts the browser, DWDS provides the
/// VM service, and an edit becomes a state-preserving hot reload. The only
/// web shape with a VM service, and therefore the only one with DevTools and
/// an app console sourced from the VM. (The agent surface is not exclusive to
/// it: a debug bundle has it too, over a page bridge.)
final class DdcWebMode extends WebMode {
  const DdcWebMode();
}

/// A `dart2wasm` bundle served statically. It has the `app.*` agent surface in
/// a debug build, reached over the Chrome DevTools Protocol through a bridge
/// the generated main installs on the page (there is no VM service). Hot
/// restart is a bazel rebuild (dart2wasm, debug) plus a page reload; hot reload
/// does not exist, because dart2wasm in this Dart SDK has no incremental
/// compiler and no way to swap code into a running module. The app console
/// arrives over CDP.
final class WasmWebMode extends WebMode {
  const WasmWebMode();
}

/// A built bundle served statically: no VM service, no reload of any kind.
/// What `--profile` and `--no-hot` resolve to on a browser. The app console
/// arrives over CDP; a screenshot is CDP's `Page.captureScreenshot`. A debug
/// bundle (`--no-hot -c dbg`) has the agent surface over the page bridge; a
/// profile or release one compiles it out.
final class StaticWebMode extends WebMode {
  const StaticWebMode();
}

/// Why a web run does or does not use dart2wasm. Decided by [selectWasm].
enum WasmSelection {
  /// Neither asked for nor called for.
  notWasm(wasm: false),

  /// `--wasm`.
  requested(wasm: true),

  /// The target is WebAssembly only (`js_fallback = False`) and the user said
  /// nothing: it ships no JavaScript, so a dev loop that runs JavaScript
  /// (DDC) would run a program the app never ships, and break on code that
  /// only works under dart2wasm.
  wasmOnlyTarget(wasm: true),

  /// `--no-wasm` on a WebAssembly-only target: the DDC dev loop, deliberately.
  /// The run goes ahead, and says what it costs.
  ddcDespiteWasmOnlyTarget(wasm: false);

  const WasmSelection({required this.wasm});

  /// Whether this run is the dart2wasm dev loop.
  final bool wasm;
}

/// Whether [selectWasm] has to be told if the target is WebAssembly only.
///
/// Only a run that would otherwise be the DDC dev loop has a choice to make,
/// and learning the fact costs a bazel query, so a run that has no use for it
/// does not pay for it. `--wasm` already chose; `--profile` and `--no-hot` run
/// a built bundle, which for a WebAssembly-only target is WebAssembly
/// whatever the loop.
bool needsWasmOnlyFact({
  required bool isWebDevice,
  required bool? wasmFlag,
  required bool profileMode,
  required bool hotReloadEnabled,
}) => isWebDevice && wasmFlag != true && !profileMode && hotReloadEnabled;

/// Whether a run uses dart2wasm, from `--wasm`/`--no-wasm` ([wasmFlag], null
/// when neither was passed) and whether the target is WebAssembly only
/// ([targetWasmOnly], null when not asked or not knowable).
///
/// Passing the flag either way is a request for a browser, and an error
/// anywhere else: a flag that cannot mean anything here is never silently
/// dropped.
WasmSelection selectWasm({
  required bool isWebDevice,
  required bool? wasmFlag,
  required bool? targetWasmOnly,
}) {
  if (!isWebDevice) {
    if (wasmFlag != null) {
      throw DevToolException(
        '--${wasmFlag ? '' : 'no-'}wasm only applies to a browser: it '
        'selects how a web run compiles and reloads, and this run is not on '
        'a web device. Drop it, or run with -d chrome.',
      );
    }
    return WasmSelection.notWasm;
  }
  if (wasmFlag == true) return WasmSelection.requested;
  if (targetWasmOnly == true) {
    return wasmFlag == false
        ? WasmSelection.ddcDespiteWasmOnlyTarget
        : WasmSelection.wasmOnlyTarget;
  }
  return WasmSelection.notWasm;
}

/// The one derivation of a run's [WebMode] from its flags. `null` for a
/// native run.
///
/// Refusals, not reinterpretations — a flag that cannot mean anything here is
/// an error, never silently dropped:
///
///  * `--wasm` or `--no-wasm` without a web device ([selectWasm]).
///  * an explicit `--hot` with the wasm loop, however it was chosen.
///    `--hot` defaults to on, so only a flag the user actually typed
///    ([hotExplicit]) counts as asking; the default quietly stepping aside for
///    WASM is fine, the explicit request being reinterpreted as "restart only"
///    is not.
///
/// `--profile` outranks the `--hot` default, exactly as
/// `RunPlan.compilationModeFor` already ranks them for the build. With
/// `--wasm` the run is [WasmWebMode] whatever `--profile` says: rebuild plus
/// page reload works identically in any compilation mode, so profile only
/// changes what the rebuild builds.
WebMode? resolveWebMode({
  required bool isWebDevice,
  required WasmSelection wasm,
  required bool profileMode,
  required bool hotReloadEnabled,
  required bool hotExplicit,
}) {
  if (!isWebDevice) return null;
  if (wasm.wasm) {
    if (hotExplicit && hotReloadEnabled) {
      throw DevToolException(
        '--hot cannot be honored with the dart2wasm dev loop: dart2wasm in '
        'this Dart SDK has no incremental compiler and no way to swap code '
        'into a running module, so a WASM run has no hot reload — only '
        'restart (a bazel rebuild plus a page reload). Upstream `flutter run '
        '--wasm` restarts on reload too; this tool refuses rather than '
        'silently restarting.\n'
        '${wasm == WasmSelection.wasmOnlyTarget ? 'The target is WebAssembly '
                  'only (`js_fallback = False`), which is why this run is the '
                  'dart2wasm loop. Drop --hot, or pass --no-wasm for the DDC '
                  '(JavaScript) loop with hot reload, which runs code the app '
                  'does not ship.' : 'Drop --hot, or drop --wasm to get the '
                  'DDC dev loop with hot reload.'}',
      );
    }
    return const WasmWebMode();
  }
  if (profileMode || !hotReloadEnabled) return const StaticWebMode();
  return const DdcWebMode();
}
