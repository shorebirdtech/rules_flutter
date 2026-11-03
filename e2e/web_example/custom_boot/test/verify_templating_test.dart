/// Verifies the bytes the templating pass actually shipped.
///
/// The rule's own analysis tests assert the plumbing — that the action runs,
/// with what config, producing which outputs — and the tool's unit tests
/// assert the substitution. Neither reads a built bundle, so this is what
/// proves the two halves meet: a `web/flutter_bootstrap.js` that a user wrote
/// is what ships, carrying values only the build knew.
///
/// Runs as a Bazel dart_test with the bundles as data dependencies.
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
  final customBoot = runfiles.rlocation('_main/custom_boot/custom_boot_web');
  final inlineBoot = runfiles.rlocation('_main/custom_boot/inline_boot_web');

  var failed = false;
  void fail(String message) {
    stderr.writeln('FAIL — $message');
    failed = true;
  }

  String read(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      fail('expected file not found at $path');
      return '';
    }
    return file.readAsStringSync();
  }

  // -- Tier 1, both templates supplied ------------------------------------
  final index = read('$customBoot/index.html');

  if (!index.contains('content="https://api.example.com"')) {
    fail('web_defines did not reach index.html:\n$index');
  }
  if (index.contains('{{API_URL}}')) {
    fail('index.html still carries the unsubstituted {{API_URL}}');
  }
  if (!index.contains('<div id="tpl">{{vueThing}}</div>')) {
    fail(
      'keep_placeholders did not survive into index.html — a page that '
      'hands {{...}} to a client-side engine needs it shipped as written',
    );
  }
  if (!index.contains('<base href="/">')) {
    fail(r'$FLUTTER_BASE_HREF was not substituted in index.html');
  }

  final bootstrap = read('$customBoot/flutter_bootstrap.js');

  // The override: the user's file is what ships.
  if (!bootstrap.contains('rules_flutter_custom_bootstrap_marker')) {
    fail('the bundle shipped its own bootstrap, not web/flutter_bootstrap.js');
  }
  // ...carrying what only the build knew.
  if (!bootstrap.contains('_flutter.buildConfig = {')) {
    fail(
      '{{flutter_build_config}} did not reach the user bootstrap; the '
      'loader would have nothing to boot',
    );
  }
  if (!bootstrap.contains('"compileTarget":"dart2wasm"')) {
    fail("the build config is not this target's:\n$bootstrap");
  }
  if (!bootstrap.contains('serviceWorkerVersion: "rules_flutter_')) {
    fail('{{flutter_service_worker_version}} did not reach the user bootstrap');
  }
  if (bootstrap.contains('{{')) {
    fail('the shipped bootstrap still carries a placeholder:\n$bootstrap');
  }

  // -- Tier 2, bootstrap inlined into the page -----------------------------
  final inlineIndex = read('$inlineBoot/index.html');
  final inlineBootstrap = read('$inlineBoot/flutter_bootstrap.js');

  if (inlineIndex.contains('{{flutter_bootstrap_js}}')) {
    fail('inline_boot/index.html still carries {{flutter_bootstrap_js}}');
  }
  if (!inlineIndex.contains('_flutter.buildConfig = {')) {
    fail('the bootstrap was not inlined into inline_boot/index.html');
  }
  // Inlined *after* substitution, not as the raw template — the ordering the
  // pass exists to guarantee.
  if (!inlineIndex.contains(inlineBootstrap.trim())) {
    fail(
      'index.html inlined something other than the substituted bootstrap:\n'
      '--- index.html ---\n$inlineIndex\n'
      '--- bootstrap ---\n$inlineBootstrap',
    );
  }

  if (failed) {
    exit(1);
  }
  print('All web templating checks passed.');
}
