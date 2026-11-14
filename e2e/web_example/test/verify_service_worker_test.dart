/// Verifies what every built bundle says about service workers.
///
/// What ships is Flutter's own teardown worker: it unregisters itself and
/// reloads its clients, releasing a visitor still holding a cache-first worker
/// from an earlier `flutter build web`. A cache-first worker must never ship
/// here — a browser installs an update only when the worker script differs
/// byte for byte, so one that caches `/` and `index.html` can pin a visitor to
/// a single build permanently, with no way to reach them afterwards.
///
/// Runs as a Bazel dart_test with the bundles as data dependencies.
library;

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/web_bundle.dart';

void main() {
  final check = BundleCheck();

  /// Asserts the shape of a bundle that ships the worker (`pwa = True`).
  void checkPwaBundle(String label, String workspacePath) {
    final bundle = WebBundle.fromRunfiles(workspacePath, check, label: label);
    final failuresBefore = check.failures.length;

    final worker = bundle.read('flutter_service_worker.js');
    if (worker != null) {
      if (!worker.contains('self.registration.unregister()')) {
        check.fail('$label: the worker does not unregister itself');
      }
      if (!worker.contains('client.navigate(client.url)')) {
        check.fail(
          '$label: the worker does not reload its clients, so a client '
          'controlled by the old caching worker keeps reading its cache',
        );
      }
      // A worker that touches the Cache API is the bug this test exists for.
      for (final banned in const [
        'caches.open',
        'caches.match',
        'cache.addAll',
        'CACHE_NAME',
      ]) {
        if (worker.contains(banned)) {
          check.fail('$label: the worker caches (`$banned` present)');
        }
      }
    }

    final bootstrap = bundle.read('flutter_bootstrap.js');
    if (bootstrap != null) {
      if (!bootstrap.contains('serviceWorkerSettings')) {
        check.fail(
          '$label: flutter_bootstrap.js does not pass serviceWorkerSettings, '
          'so flutter.js never registers the worker and a visitor holding '
          'the old caching worker is never freed',
        );
      }
      // Passing serviceWorkerUrl takes flutter.js's unconditional-register
      // branch, which installs a worker for first-time visitors who have
      // nothing to tear down — and warns about deprecation in their console.
      if (bootstrap.contains('serviceWorkerUrl')) {
        check.fail('$label: flutter_bootstrap.js sets serviceWorkerUrl');
      }
    }

    final index = bundle.read('index.html');
    if (index != null && index.contains('navigator.serviceWorker.register')) {
      check.fail(
        '$label: index.html registers the worker itself; registration '
        'belongs to flutter.js, which also waits for activation and times out',
      );
    }

    if (check.failures.length == failuresBefore) {
      check.pass('$label: teardown worker, registered via loader');
    }
  }

  /// Asserts a `pwa = False` bundle ships and says nothing about workers.
  void checkNoPwaBundle(String label, String workspacePath) {
    final bundle = WebBundle.fromRunfiles(workspacePath, check, label: label);
    final failuresBefore = check.failures.length;

    if (bundle.file('flutter_service_worker.js').existsSync()) {
      check.fail('$label: pwa = False still emitted flutter_service_worker.js');
    }
    final bootstrap = bundle.read('flutter_bootstrap.js');
    if (bootstrap != null && bootstrap.contains('serviceWorkerSettings')) {
      check.fail('$label: pwa = False still registers a service worker');
    }
    if (check.failures.length == failuresBefore) {
      check.pass('$label: no worker, no registration');
    }
  }

  // Tier 1 (flutter_web_app), user-provided web/index.html.
  checkPwaBundle('app_wasm', 'app_wasm_web');

  // Tier 2 (flutter_web_bundle) with a generated index.html — the other path
  // through index.html generation, and a dart2js-only bundle.
  checkPwaBundle('app_js', 'app_js_web');

  checkNoPwaBundle('app_no_pwa', 'app_no_pwa_web');

  check.finish('All service worker checks passed.');
}
