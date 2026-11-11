/// Domain-level compile interface used by the reload pipeline.
///
/// `Compiler` is an abstraction over `FrontendServer`: tests inject a
/// `FakeCompiler`; production wires up `FrontendServerCompiler`. The
/// outcome is a sealed type so the caller's switch is exhaustive.
///
/// `Compiler` does not track "what's already applied to the running app"
/// — that's `AppliedVersions`'s job, and the orchestrator composes them.
import '../frontend_server.dart';

/// Outcome of a single compile request.
sealed class CompileOutcome {
  const CompileOutcome();
}

/// The compile produced a kernel artifact at [dillPath].
///
/// Whether the artifact represents a no-op delta is *not* this layer's
/// concern — the orchestrator decides that by comparing source `Version`s
/// against `AppliedVersions`. Pushing it here would couple `Compiler` to
/// applied-state tracking it doesn't otherwise need.
class CompileSucceeded extends CompileOutcome {
  final String dillPath;
  const CompileSucceeded(this.dillPath);
}

/// The compile failed; [diagnostics] is whatever the frontend_server
/// emitted on stderr/stdout before reporting non-zero error count.
class CompileFailed extends CompileOutcome {
  final String diagnostics;
  const CompileFailed(this.diagnostics);
}

/// Domain-level compile interface.
abstract interface class Compiler {
  /// Recompile, treating [invalidated] as the set of changed source URIs.
  ///
  /// Single-flight: a second concurrent call cancels the first (the
  /// pending future of the cancelled call completes with `CompileFailed`).
  Future<CompileOutcome> compileIncrement({
    required Set<String> invalidated,
    required String entrypoint,
  });

  /// The whole program, for a hot restart.
  ///
  /// [invalidated] is what changed since the committed baseline, as for
  /// [compileIncrement], and it decides what is recompiled: the compiler
  /// reuses every other library it holds, and only its answer differs, a
  /// whole program instead of a delta. A changed file left out comes back as
  /// its old code.
  Future<CompileOutcome> compileFull({
    required String entrypoint,
    required Set<String> invalidated,
  });

  /// Make the most recent successful compile the new committed baseline.
  Future<void> commit();

  /// Discard the most recent compile; revert to the previous baseline.
  Future<void> rollback();

  Future<void> shutdown();
}

/// Production [Compiler] backed by the persistent `frontend_server`.
class FrontendServerCompiler implements Compiler {
  final FrontendServer _server;

  FrontendServerCompiler(this._server);

  @override
  Future<CompileOutcome> compileIncrement({
    required Set<String> invalidated,
    required String entrypoint,
  }) async {
    final result = await _server.recompile(entrypoint, invalidated.toList());
    return _toOutcome(result);
  }

  /// `reset` + `recompile`, never a second `compile`.
  ///
  /// The reset is what makes the answer a whole program instead of a delta;
  /// the `recompile` verb is what keeps the compiler's error list from
  /// carrying an earlier failure forward into this answer. See
  /// [FrontendServer.recompile], and `flutter_tools`' `devfs.dart` for the same
  /// pairing upstream.
  @override
  Future<CompileOutcome> compileFull({
    required String entrypoint,
    required Set<String> invalidated,
  }) async {
    final result = await _server.recompile(
      entrypoint,
      invalidated.toList(),
      resetFirst: true,
    );
    return _toOutcome(result);
  }

  @override
  Future<void> commit() async => _server.accept();

  @override
  Future<void> rollback() async => _server.reject();

  @override
  Future<void> shutdown() async => _server.shutdown();

  CompileOutcome _toOutcome(CompileResult result) {
    if (result.success) return CompileSucceeded(result.dillPath);
    return CompileFailed(result.diagnostics);
  }
}
