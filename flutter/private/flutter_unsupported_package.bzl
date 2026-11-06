"""Spoke for a lock entry rules_flutter has no repository for.

A `pubspec.lock` lists packages from sources rules_flutter cannot provide: git
packages, and sources it has never heard of. (Hosted packages and `sdk: flutter`
packages it builds, and `path` packages are the user's own targets; see
`lock_entry_kind.bzl`.) A hub that failed to load over such an entry would break
every app that merely lists it, a git-sourced `dev_dependencies` entry being the
usual case, even though nothing in Bazel uses it.

The hub therefore still lists the package. Its target is a stub that fails when
Bazel analyses something that depends on it, with a message naming the package,
where the lock got it from, and what to do. Nothing that does not depend on it is
affected.
"""

def _unsupported_package_impl(ctx):
    fail(ctx.attr.message)

unsupported_package = rule(
    implementation = _unsupported_package_impl,
    attrs = {
        "message": attr.string(mandatory = True),
    },
    doc = "A package target that fails analysis with `message`. See the file docstring.",
)

def unsupported_package_message(lock, package, source):
    """Why rules_flutter cannot provide a lock entry, and what to do about it.

    Args:
        lock: The lock file's label, for the message.
        package: The package name.
        source: The entry's `source:` in the lock.

    Returns:
        The message.
    """
    if source == "git":
        advice = (
            "rules_flutter fetches hosted packages and builds the Flutter SDK packages, " +
            "not git packages. Depend on a hosted release of \"{}\" and re-resolve the lock."
        ).format(package)
    else:
        advice = (
            "rules_flutter fetches hosted packages and builds the Flutter SDK packages, " +
            "not packages from a \"{}\" source. Depend on a hosted release of \"{}\" " +
            "and re-resolve the lock."
        ).format(source, package)
    return "package \"{}\" (source: {}) in {} cannot be built: {}".format(
        package,
        source,
        lock,
        advice,
    )

def _flutter_unsupported_package_impl(repository_ctx):
    package = repository_ctx.attr.package_name
    repository_ctx.file("BUILD.bazel", """\
load("@rules_flutter//flutter/private:flutter_unsupported_package.bzl", "unsupported_package")

unsupported_package(
    name = {name},
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = repr(package), message = repr(repository_ctx.attr.message)))

flutter_unsupported_package = repository_rule(
    implementation = _flutter_unsupported_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "message": attr.string(
            mandatory = True,
            doc = "What the package's target fails with (see `unsupported_package_message`).",
        ),
    },
    doc = "A hub spoke whose package target fails analysis; for lock entries rules_flutter cannot provide.",
)
