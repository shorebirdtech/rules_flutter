/// Chrome on another Mac, for a web run of the dev tool on this one: point
/// `CHROME_EXECUTABLE` at this program and set `RULES_FLUTTER_CHROME_HOST` to
/// an ssh destination.
///
/// The dev tool starts this with the command line it gives Chrome. This runs
/// the host's Chrome with that command line over ssh, the page's dev server
/// forwarded to the host's loopback (`ssh -R`) so the page loads from the
/// same `http://localhost:<port>` URL, and Chrome's debugging port forwarded
/// back (`ssh -L`), so its announcement on stderr — which the dev tool reads
/// for the port — names a port that answers here. The browser's window opens
/// on the host's screen; the dev tool, its builds and its server stay here.
///
/// Stopping this program (SIGTERM, SIGINT, or its stdin to ssh closing
/// because it was killed outright) quits that Chrome and removes the profile
/// directory it was given there, a fresh one: the dev tool's is a path on
/// this machine.
library;

import 'dart:async';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/remote_chrome.dart';

const _hostVariable = 'RULES_FLUTTER_CHROME_HOST';
const _remoteChrome =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

Future<void> main(List<String> args) async {
  final host = Platform.environment[_hostVariable];
  if (host == null || host.isEmpty) {
    stderr.writeln(
      'ssh_chrome: $_hostVariable is not set: it names the ssh destination '
      'whose Chrome to open.',
    );
    exit(2);
  }

  final launch = RemoteChromeLaunch.parse(args, debugPort: await _freePort());
  final process = await Process.start('ssh', [
    '-o', 'BatchMode=yes', //
    '-o', 'ExitOnForwardFailure=yes',
    '-L', '${launch.debugPort}:127.0.0.1:${launch.debugPort}',
    '-R', '${launch.serverPort}:localhost:${launch.serverPort}',
    host,
    launch.remoteScript(_remoteChrome),
  ]);
  unawaited(stdout.addStream(process.stdout));
  unawaited(stderr.addStream(process.stderr));

  // The remote script quits Chrome when its stdin ends, so closing it is the
  // one way to stop the run there. Its other end is this process: if this is
  // killed outright, the pipe closes and the host is told the same.
  var stopping = false;
  Future<void> stop(ProcessSignal _) async {
    if (stopping) return;
    stopping = true;
    await process.stdin.close();
    final exited = await process.exitCode
        .then((_) => true)
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!exited) process.kill(ProcessSignal.sigkill);
  }

  final subscriptions = [
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint])
      signal.watch().listen(stop),
  ];
  final code = await process.exitCode;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  exit(stopping ? 0 : code);
}

/// A port free on this machine at the moment of asking, for the forwarded
/// debugging port. Chrome is told to take the same number on the host.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
