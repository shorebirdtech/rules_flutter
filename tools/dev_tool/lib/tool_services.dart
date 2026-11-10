/// The services this tool offers the other clients of an app's VM service.
///
/// A client of a running Flutter app — DevTools' reload and restart buttons,
/// the Dart MCP server's `hot_reload` and `hot_restart` tools — reloads by
/// looking for a *registered* `reloadSources` or `hotRestart` service and
/// calling that. Finding none, it calls the VM's own `reloadSources`, which
/// reloads from whatever kernel the VM last had: the edit is never compiled, so
/// it never loads. `flutter_tools` registers both (`vmservice.dart`,
/// `setUpVmService`), and so does this tool, routed to the same commands `r`,
/// `R`, `app.hotReload` and `app.restart` reach.
library;

import 'package:vm_service/vm_service.dart';

import 'command_failure.dart';
import 'command_runner.dart';

/// Told the outcome of a reload or restart a VM service client asked for.
///
/// [method] is the command it ran (`app.hotReload`, `app.restart`). The client
/// that asked gets its answer in the service response; this is for everyone
/// else watching the run — the terminal and a `--machine` client — who would
/// otherwise see their app change with nothing said about it.
typedef ToolServiceReporter = void Function(
  String action,
  Map<String, dynamic> result, {
  required String method,
});

/// Registers `reloadSources` and, optionally, `hotRestart` on a VM service.
///
/// Registered per connection, because DDS drops a client's registrations when
/// that client disconnects: [VmServiceClient] calls [registerOn] on every
/// connect, re-dials included.
///
/// Registering does not capture this tool's own raw calls on the same
/// connection. DDS (and the VM) resolve a registered service only under the
/// registering client's namespace (`s0.reloadSources`), so the bare
/// `reloadSources` the reload path sends still reaches the VM.
class ToolServices {
  /// The name every registration carries, shown to clients that list them.
  static const alias = 'rules_flutter dev_tool';

  static const reloadSourcesService = 'reloadSources';
  static const hotRestartService = 'hotRestart';

  final CommandRunner _commands;
  final ToolServiceReporter _report;

  /// Whether to register `hotRestart` as well as `reloadSources`.
  ///
  /// False for a browser run, as in `flutter_tools`' web runner: DWDS
  /// registers its own `hotRestart` on the same DDS, and this tool's restart
  /// path calls that one (`DwdsReloadStrategy`). A second registration under
  /// the same name would leave clients choosing between them by event order,
  /// and could have the restart path find this tool's own service and call
  /// itself.
  final bool hotRestart;

  ToolServices({
    required CommandRunner commands,
    required ToolServiceReporter report,
    this.hotRestart = true,
  }) : _commands = commands,
       _report = report;

  /// The same services without `hotRestart`. See [hotRestart].
  ToolServices withoutHotRestart() =>
      ToolServices(commands: _commands, report: _report, hotRestart: false);

  /// Install the handlers on [service] and announce them.
  ///
  /// Handlers go in before the registrations are sent: DDS forwards a call to
  /// a service the moment it is registered, and a call that arrived first
  /// would be answered "method not found".
  Future<void> registerOn(VmService service) async {
    service.registerServiceCallback(reloadSourcesService, _reloadSources);
    if (hotRestart) {
      service.registerServiceCallback(hotRestartService, _hotRestart);
    }
    await Future.wait([
      service.registerService(reloadSourcesService, alias),
      if (hotRestart) service.registerService(hotRestartService, alias),
    ]);
  }

  /// `reloadSources`, with `flutter_tools`' parameters: `isolateId` (required,
  /// as there), `force` and `pause`.
  ///
  /// Reloads every app in the run, as `flutter_tools`' does: it is the same
  /// reload `r` performs, not a reload of the one isolate named.
  Future<Map<String, dynamic>> _reloadSources(
    Map<String, dynamic> params,
  ) async {
    _stringParam(reloadSourcesService, params, 'isolateId');
    _boolParam(reloadSourcesService, params, 'force');
    _refusePause(reloadSourcesService, params);
    return _run(
      service: reloadSourcesService,
      action: 'Hot reload',
      command: 'app.hotReload',
      unable: 'Unable to reload sources',
    );
  }

  Future<Map<String, dynamic>> _hotRestart(Map<String, dynamic> params) async {
    _refusePause(hotRestartService, params);
    return _run(
      service: hotRestartService,
      action: 'Hot restart',
      command: 'app.restart',
      unable: 'Unable to restart',
    );
  }

  /// Run [command] and answer the way `flutter_tools` does: `Success` when it
  /// worked, an `RPCError` when it did not — with the reason as its details,
  /// which `flutter_tools` leaves empty.
  Future<Map<String, dynamic>> _run({
    required String service,
    required String action,
    required String command,
    required String unable,
  }) async {
    Map<String, dynamic> result;
    try {
      result = await _commands.run(command, const {});
    } on CommandFailure catch (e) {
      // A refusal is the same answer as a reload that failed, to a client
      // that only asked whether it worked.
      result = {'error': e.message};
    }
    _report(action, result, method: command);
    if (result['error'] case final error?) {
      throw RPCError.withDetails(
        service,
        RPCErrorKind.kInternalError.code,
        unable,
        details: '$error',
      );
    }
    return {
      'result': {'type': 'Success'},
    };
  }

  /// This tool reloads and restarts without pausing; `pause: true` asks it to
  /// leave the isolate paused afterwards, which it cannot do. Refused rather
  /// than ignored, so a debugger that asked for it is not left believing it
  /// got it.
  static void _refusePause(String method, Map<String, dynamic> params) {
    if (_boolParam(method, params, 'pause')) {
      throw RPCError(
        method,
        RPCErrorKind.kInvalidParams.code,
        "'pause: true' is not supported: flutter_bazel does not leave the "
        'isolate paused after a reload or restart.',
      );
    }
  }

  static bool _boolParam(
    String method,
    Map<String, dynamic> params,
    String name,
  ) {
    final value = params[name];
    if (value != null && value is! bool) {
      throw RPCError(
        method,
        RPCErrorKind.kInvalidParams.code,
        "Invalid '$name': $value",
      );
    }
    return value as bool? ?? false;
  }

  static String _stringParam(
    String method,
    Map<String, dynamic> params,
    String name,
  ) {
    final value = params[name];
    if (value is! String) {
      throw RPCError(
        method,
        RPCErrorKind.kInvalidParams.code,
        "Invalid '$name': $value",
      );
    }
    return value;
  }
}
