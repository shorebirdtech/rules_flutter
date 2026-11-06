"""Reconciling a package that several `flutter.pub()` locks list.

There is one repository per package for the whole build, so when more than one
lock lists a package they must agree on what it is. `reconcile_package` decides,
from the entries every lock has for the package, which one the build uses, or
why none can be.

Every function here is pure and returns messages instead of calling `fail`: a
unit test cannot catch `fail`. The extension joins the messages and fails.

An entry is a `struct` the extension makes of one lock entry:

* `kind`: its `lock_entry_kind`;
* `version`, `sha256`, `url` (the registry's), for a hosted package;
* `git_url`, `resolved_ref`, `git_path`, `git_lock` (the lock's label when the
  url is relative to it, else `""`), for a git package;
* `hub`, `lock_label`: the tag it came from.
"""

load("//flutter/private:lock_entry_kind.bzl", "GIT", "HOSTED", "UNSUPPORTED")

def _where(entry):
    return "hub \"{}\", {}".format(entry.hub, entry.lock_label)

def _describe(entry):
    if entry.kind == HOSTED:
        return "hosted {} ({})".format(entry.version, _where(entry))
    if entry.kind == GIT:
        return "git {} at {} ({})".format(entry.git_url, entry.resolved_ref, _where(entry))
    return "{} ({})".format(entry.kind, _where(entry))

def _kinds_error(name, entries):
    return (
        "Package \"{name}\" comes from different sources across flutter.pub() locks:\n" +
        "{lines}\n" +
        "rules_flutter builds one copy of each package. Make the locks agree, or map " +
        "it to one target with `resolve`."
    ).format(
        name = name,
        lines = "\n".join(["  - " + _describe(e) for e in entries]),
    )

def _hosted_errors(name, entries):
    first = entries[0]
    for e in entries[1:]:
        if e.url != first.url:
            return [(
                "Package \"{name}\" comes from different registries across flutter.pub() locks:\n" +
                "  - {a} ({a_where})\n" +
                "  - {b} ({b_where})\n" +
                "rules_flutter builds one copy of each package. Make the locks agree."
            ).format(name = name, a = first.url, a_where = _where(first), b = e.url, b_where = _where(e))]
        if e.version == first.version and e.sha256 != first.sha256:
            return [(
                "Package \"{name}\" {version} has different digests across flutter.pub() locks:\n" +
                "  - {a} ({a_where})\n" +
                "  - {b} ({b_where})\n" +
                "One version of a package is one archive. Re-resolve the locks."
            ).format(name = name, version = first.version, a = first.sha256, a_where = _where(first), b = e.sha256, b_where = _where(e))]
    versions = {e.version: True for e in entries}
    if len(versions) > 1:
        return [(
            "Package \"{name}\" has different versions across flutter.pub() locks:\n" +
            "{lines}\n" +
            "rules_flutter builds one copy of each package. Make the locks agree: " +
            "bazel run @rules_flutter//flutter:pub -- upgrade {name}"
        ).format(
            name = name,
            lines = "\n".join(["  - {} ({})".format(e.version, _where(e)) for e in entries]),
        )]
    return []

def _git_key(entry):
    return (entry.git_url, entry.git_lock, entry.resolved_ref, entry.git_path)

def _git_errors(name, entries):
    keys = {_git_key(e): True for e in entries}
    if len(keys) > 1:
        return [(
            "Package \"{name}\" is pinned to different git sources across flutter.pub() locks:\n" +
            "{lines}\n" +
            "rules_flutter builds one copy of each package. Make the locks agree."
        ).format(
            name = name,
            lines = "\n".join(["  - {} ({})".format(_describe(e), _where(e)) for e in entries]),
        )]
    return []

def reconcile_package(name, entries):
    """Decides which of a package's lock entries the build uses.

    Args:
        name: The package's name.
        entries: Its entries, one per lock that lists it (see the file doc).

    Returns:
        `struct(entry, errors)`: `entry`, the one the build uses (None when
        `errors` is set); `errors`, the messages, empty when the locks agree.
    """
    kinds = {e.kind: True for e in entries}
    if len(kinds) > 1:
        return struct(entry = None, errors = [_kinds_error(name, entries)])
    kind = entries[0].kind
    errors = []
    if kind == HOSTED:
        errors = _hosted_errors(name, entries)
    elif kind == GIT:
        errors = _git_errors(name, entries)
    if errors:
        return struct(entry = None, errors = errors)
    return struct(entry = entries[0], errors = [])

def unsupported_locks(entries):
    """The locks that list an unsupported package, for its one stub's message.

    Args:
        entries: The package's entries, of kind `UNSUPPORTED`.

    Returns:
        The lock labels, joined.
    """
    return ", ".join(sorted({e.lock_label: True for e in entries if e.kind == UNSUPPORTED}.keys()))
