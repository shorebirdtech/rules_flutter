"""The Dart package the fixtures instantiated in `//flutter/tests` are part of.

A directory is one Dart package, declared by its one `pubspec-metadata`, so
every fixture this BUILD file instantiates is in this package, rooted here. A
fixture needing another package's facts lives in a directory of its own.
"""

TESTS_PACKAGE = "flutter_tests"

# Deliberately not the SDK's own version: a test that the version is forwarded
# would pass whether or not it was, since an absent one reads as the SDK's.
TESTS_LANGUAGE_VERSION = "3.12"
