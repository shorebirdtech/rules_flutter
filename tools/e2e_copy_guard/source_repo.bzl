"""Canonical repo name of this package, for `package:runfiles` repo mapping.

Mirrors `//tools/dev_tool:source_repo.bzl`.
"""

SOURCE_REPO = Label("//tools/e2e_copy_guard:copies_identical_test").workspace_name
