/// [resolveWebMode] — the one derivation of a web run's shape from its flags.
///
/// Every case goes through the real `run` parser, so a default that changes
/// there (notably `--hot` defaulting to on) changes here too, and the
/// `hotExplicit` distinction is exercised the way `RunPlan.resolve` will
/// exercise it: `wasParsed`, not the value.
import 'package:args/args.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/run_command.dart' show RunCommand;
import 'package:flutter_bazel_dev_tool/web_mode.dart';
import 'package:test/test.dart';

/// Resolve the mode for one set of `run` flags, exactly as the plan will:
/// raw flag values plus `wasParsed('hot')`, against a web or native device.
///
/// [wasmOnly] is what the target's bundle says (`js_fallback = False`), as
/// the plan reads it from bazel; like the plan, this asks the question only
/// of a run that [needsWasmOnlyFact], so a run that has no use for it never
/// sees the answer.
WebMode? resolveFor(
  List<String> args, {
  bool web = true,
  bool? wasmOnly,
}) {
  final ArgResults r = RunCommand.parser.parse(['-t', '//:app', ...args]);
  final wasmFlag = r['wasm'] as bool?;
  final wasm = selectWasm(
    isWebDevice: web,
    wasmFlag: wasmFlag,
    targetWasmOnly:
        needsWasmOnlyFact(
          isWebDevice: web,
          wasmFlag: wasmFlag,
          profileMode: r['profile'] as bool,
          hotReloadEnabled: r['hot'] as bool,
        )
        ? wasmOnly
        : null,
  );
  return resolveWebMode(
    isWebDevice: web,
    wasm: wasm,
    profileMode: r['profile'] as bool,
    hotReloadEnabled: r['hot'] as bool,
    hotExplicit: r.wasParsed('hot'),
  );
}

Matcher throwsDevTool(Object matcher) => throwsA(
  isA<DevToolException>().having((e) => e.message, 'message', matcher),
);

void main() {
  group('a native run', () {
    test('has no web mode, whatever the web flags default to', () {
      expect(resolveFor([], web: false), isNull);
      expect(resolveFor(['--profile'], web: false), isNull);
      expect(resolveFor(['--no-hot'], web: false), isNull);
    });

    // The old gate was `isWebDevice && wasm`, so on a native device the
    // flag fell through every branch and did nothing — the user asked for a
    // WASM run and got a native one with no mention of the flag.
    test('refuses --wasm instead of silently ignoring it', () {
      expect(
        () => resolveFor(['--wasm'], web: false),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('-d chrome'),
          ),
        ),
      );
    });

    test('refuses --no-wasm too: it chooses a web dev loop', () {
      expect(
        () => resolveFor(['--no-wasm'], web: false),
        throwsDevTool(contains('--no-wasm only applies to a browser')),
      );
    });
  });

  group('a web run', () {
    test('defaults to the DDC dev loop', () {
      expect(resolveFor([]), isA<DdcWebMode>());
    });

    test('--profile is a static bundle — AOT-style, no dev loop', () {
      expect(resolveFor(['--profile']), isA<StaticWebMode>());
    });

    test('--no-hot is a static bundle — no reload was asked for', () {
      expect(resolveFor(['--no-hot']), isA<StaticWebMode>());
    });

    // `--hot` defaults to on and `--profile` outranks it, the same ranking
    // compilationModeFor applies to the build. An explicit --hot does not
    // change that: profile has never had a reload pipeline anywhere.
    test('--profile outranks --hot, explicit or defaulted', () {
      expect(resolveFor(['--profile', '--hot']), isA<StaticWebMode>());
    });

    test('--wasm is the WASM loop', () {
      expect(resolveFor(['--wasm']), isA<WasmWebMode>());
    });

    test('--wasm --no-hot is still the WASM loop', () {
      expect(resolveFor(['--wasm', '--no-hot']), isA<WasmWebMode>());
    });

    // The old WASM gate ignored --profile while the DDC gate refused it, so
    // `--wasm --profile` ran both the profile session and the WASM handlers
    // by accident. Deliberate now: rebuild + page reload works identically in
    // any compilation mode, so profile only changes what the rebuild builds.
    test('--wasm --profile is the WASM loop, deliberately', () {
      expect(resolveFor(['--wasm', '--profile']), isA<WasmWebMode>());
    });

    // The default quietly stepping aside for WASM is fine; the user's typed
    // request being reinterpreted as "restart only" is not.
    test('an explicit --hot with --wasm is refused, not reinterpreted', () {
      expect(
        () => resolveFor(['--wasm', '--hot']),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('no hot reload'),
          ),
        ),
      );
    });
  });

  // An app that ships WebAssembly only (`js_fallback = False`) never ships
  // the JavaScript the DDC loop runs, so developing it there runs a program
  // that is not the app: `Int64List` throws under DDC and works everywhere
  // the app is deployed.
  group('a web run of a WebAssembly-only target', () {
    test('is the WASM loop with no flags', () {
      expect(resolveFor([], wasmOnly: true), isA<WasmWebMode>());
    });

    test('is the WASM loop with --wasm, as always', () {
      expect(resolveFor(['--wasm'], wasmOnly: true), isA<WasmWebMode>());
    });

    test('is DDC when --no-wasm asks for it', () {
      expect(resolveFor(['--no-wasm'], wasmOnly: true), isA<DdcWebMode>());
    });

    // The default hot reload stepping aside is not a collision; a typed
    // `--hot` is, and the refusal says why this run is not the DDC loop.
    test('refuses an explicit --hot, and names the target as the cause', () {
      expect(
        () => resolveFor(['--hot'], wasmOnly: true),
        throwsDevTool(
          allOf(contains('no hot reload'), contains('js_fallback = False')),
        ),
      );
    });

    test('lets --hot through once --no-wasm picks the DDC loop', () {
      expect(
        resolveFor(['--no-wasm', '--hot'], wasmOnly: true),
        isA<DdcWebMode>(),
      );
    });

    // These run a built bundle, which for such a target is WebAssembly
    // whichever loop serves it, so there is no choice to make.
    test('keeps --profile and --no-hot as static bundles', () {
      expect(
        resolveFor(['--profile'], wasmOnly: true),
        isA<StaticWebMode>(),
      );
      expect(resolveFor(['--no-hot'], wasmOnly: true), isA<StaticWebMode>());
    });
  });

  group('a web run of a target that also ships JavaScript', () {
    test('stays the DDC loop with no flags', () {
      expect(resolveFor([], wasmOnly: false), isA<DdcWebMode>());
    });

    test('stays the DDC loop with --no-wasm, which is not a surprise', () {
      expect(resolveFor(['--no-wasm'], wasmOnly: false), isA<DdcWebMode>());
    });
  });

  group('needsWasmOnlyFact', () {
    bool needs({
      bool web = true,
      bool? wasmFlag,
      bool profile = false,
      bool hot = true,
    }) => needsWasmOnlyFact(
      isWebDevice: web,
      wasmFlag: wasmFlag,
      profileMode: profile,
      hotReloadEnabled: hot,
    );

    test('only a run that would be DDC asks', () {
      expect(needs(), isTrue);
      expect(needs(wasmFlag: false), isTrue);
      expect(needs(wasmFlag: true), isFalse);
      expect(needs(profile: true), isFalse);
      expect(needs(hot: false), isFalse);
      expect(needs(web: false), isFalse);
    });
  });
}
