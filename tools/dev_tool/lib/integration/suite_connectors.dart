/// How the host reaches the suite of a launched app: one connector per kind of
/// device, which turns a launched [AppInstance] into a [SuiteTransport], or says
/// why it could not.
///
/// What the app is launched on decides what carries its suite. A native app is
/// reached through its VM service (`vm_service_suite_transport.dart`), as
/// `flutter test integration_test/x_test.dart -d <device>` does; a web app has
/// no VM service, and its page is reached over the browser's DevTools protocol
/// (`cdp_suite_transport.dart`).
library;

import 'dart:async';

import 'package:flutter_rule_tools/remote_suite.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../browser_extension_channel.dart' show CdpSender;
import '../device.dart';
import 'cdp_suite_transport.dart';
import 'golden_requests.dart';
import 'lost_before_suite.dart';
import 'vm_service_suite_transport.dart';

/// The suite of the app could not be reached, and why: what the run fails with,
/// in words that name the cause.
class SuiteUnreachable implements Exception {
  /// Says what went wrong.
  SuiteUnreachable(this.message);

  /// What the run reports.
  final String message;

  @override
  String toString() => message;
}

/// Reaches the suite of [instance], launched on [device], within [ceiling]: the
/// bound on the whole wait for the app to start it, which has no other end than
/// the app starting it or ending.
///
/// Throws a [SuiteUnreachable] saying why when it cannot.
typedef SuiteConnector = Future<IntegrationSuiteTransport> Function(
  Device device,
  AppInstance instance, {
  required Duration ceiling,
});

/// Connects to the VM service at [wsUri].
typedef VmServiceDialer = Future<VmService> Function(String wsUri);

/// Reaches the suite through the app's VM service, dialed with [dial].
SuiteConnector vmServiceConnector({
  VmServiceDialer dial = vmServiceConnectUri,
}) => (device, instance, {required ceiling}) async {
  final uri = instance.vmServiceUri;
  if (uri == null) {
    throw SuiteUnreachable(
      'the app started but did not announce a VM service, which the suite '
      'is driven through.',
    );
  }
  try {
    final service = await dial(
      uri
          .replace(
            scheme: uri.scheme == 'https' ? 'wss' : 'ws',
            path: '${uri.path}ws',
          )
          .toString(),
    );
    return await VmServiceSuiteTransport.connect(
      service,
      whyLost: () => device.whyAppExited(instance),
    ).timeout(ceiling);
  } on LostBeforeSuite catch (e) {
    throw SuiteUnreachable('$e');
  } on TimeoutException {
    throw SuiteUnreachable(
      'the app did not register $integrationTestMethod within '
      '${ceiling.inSeconds}s. Its test bootstrap, `runIntegrationSuite`, '
      'was never reached.',
    );
  }
};

/// Opens the DevTools connection to the page of [device], which serves the app.
typedef PageOpener = Future<CdpSender> Function(WebDevice device);

/// Reaches the suite through the app's page, over the browser's DevTools
/// connection that [open] makes.
SuiteConnector chromePageConnector({PageOpener open = _openPage}) =>
    (device, instance, {required ceiling}) async {
      if (device is! WebDevice) {
        throw SuiteUnreachable(
          'the page connector reaches a web app, and ${device.name} is not '
          'one.',
        );
      }
      final CdpSender page;
      try {
        page = await open(device);
      } on Object catch (e) {
        throw SuiteUnreachable(
          'could not connect to the app\'s page over the browser\'s DevTools '
          'port: $e',
        );
      }
      try {
        return await CdpSuiteTransport.connect(
          page,
          whyLost: () => device.whyAppExited(instance),
        ).timeout(ceiling);
      } on LostBeforeSuite catch (e) {
        await page.close();
        throw SuiteUnreachable('$e');
      } on TimeoutException {
        await page.close();
        throw SuiteUnreachable(
          'the page did not install the integration test bridge within '
          '${ceiling.inSeconds}s. Its test bootstrap, `runIntegrationSuite`, '
          'was never reached.',
        );
      }
    };

Future<CdpSender> _openPage(WebDevice device) {
  final port = device.cdpPort;
  final url = device.appUrl;
  if (port == null || url == null) {
    throw StateError(
      'the browser has no DevTools port or app URL yet: it was not launched.',
    );
  }
  return CdpPageConnection.open(port, appUrl: url);
}
