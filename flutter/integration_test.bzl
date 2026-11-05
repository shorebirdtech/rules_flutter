"""Integration tests: `package:integration_test` suites run on a device and reported per test.

Tier 2, the composable rules, are exported here. Their macros arrive with the
rules that run them.

- `flutter_application_variant`: a `flutter_application` rebuilt with another
  `main`, plus extra `srcs`, `deps` and `defines`. An integration test is run
  as the application with its test as the program.
"""

load("//flutter/private:flutter_application_variant.bzl", _flutter_application_variant = "flutter_application_variant")

flutter_application_variant = _flutter_application_variant
