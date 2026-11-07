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
* `hub`, `lock_label`, `on_version_conflict`: the tag it came from.
"""

load("@rules_dart//dart/pub:defs.bzl", "parse_semver")
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

def _registry_and_digest_errors(name, entries):
    first = entries[0]
    for e in entries[1:]:
        if e.url != first.url:
            return [(
                "Package \"{name}\" comes from different registries across flutter.pub() locks:\n" +
                "  - {a} ({a_where})\n" +
                "  - {b} ({b_where})\n" +
                "rules_flutter builds one copy of each package. Make the locks agree."
            ).format(name = name, a = first.url, a_where = _where(first), b = e.url, b_where = _where(e))]
    by_version = {}
    for e in entries:
        other = by_version.setdefault(e.version, e)
        if e.sha256 != other.sha256:
            return [(
                "Package \"{name}\" {version} has different digests across flutter.pub() locks:\n" +
                "  - {a} ({a_where})\n" +
                "  - {b} ({b_where})\n" +
                "One version of a package is one archive. Re-resolve the locks."
            ).format(name = name, version = e.version, a = other.sha256, a_where = _where(other), b = e.sha256, b_where = _where(e))]
    return []

def _version_error(name, entries, winner):
    behind = [e for e in entries if e.version != winner.version and e.on_version_conflict == "error"]
    if not behind:
        return []
    locks = sorted({e.lock_label: True for e in behind}.keys())
    return [(
        "Package \"{name}\" has conflicting versions across flutter.pub() locks:\n" +
        "{lines}\n\n" +
        "rules_flutter builds one version of each package, the highest a lock records.\n" +
        "{locks} pin{s} a lower one. To resolve:\n\n" +
        "  1. (Preferred) Re-resolve {those} so the package moves forward, with the\n" +
        "     toolchain that builds {them}:\n" +
        "       bazel run @rules_flutter//flutter:pub -- upgrade {name}\n" +
        "     in the directory of {each}.\n\n" +
        "  2. If {their} constraints forbid {version}, set on_version_conflict = \"upgrade\"\n" +
        "     on {that}: {its} packages are then built at the higher version."
    ).format(
        name = name,
        lines = "\n".join([
            "  - {} ({}, on_version_conflict = \"{}\")".format(e.version, _where(e), e.on_version_conflict)
            for e in entries
        ]),
        locks = ", ".join(locks),
        s = "s" if len(locks) == 1 else "",
        those = "that lock" if len(locks) == 1 else "those locks",
        them = "it" if len(locks) == 1 else "them",
        each = "that lock" if len(locks) == 1 else "each of them",
        their = "its" if len(locks) == 1 else "their",
        that = "that flutter.pub()" if len(locks) == 1 else "those flutter.pub() tags",
        its = "its" if len(locks) == 1 else "their",
        version = winner.version,
    )]

def pick_version(name, entries):
    """The one policy for which version of a hosted package the build uses.

    The highest version any lock records wins. A lock that records a lower one
    is an error unless its tag set `on_version_conflict = "upgrade"`, which
    accepts the higher version. Nothing is ever built below the version its
    lock records. Another policy is a change to this function alone.

    Args:
        name: The package's name.
        entries: Its hosted entries, which agree on the registry and on the
            digest of each version.

    Returns:
        `struct(entry, errors)`: the winning entry, and the messages.
    """
    winner = entries[0]
    for e in entries[1:]:
        if parse_semver(e.version) > parse_semver(winner.version):
            winner = e
    return struct(entry = winner, errors = _version_error(name, entries, winner))

def _hosted_errors(name, entries):
    return _registry_and_digest_errors(name, entries)

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
        if not errors:
            picked = pick_version(name, entries)
            return struct(entry = None if picked.errors else picked.entry, errors = picked.errors)
    elif kind == GIT:
        errors = _git_errors(name, entries)
    if errors:
        return struct(entry = None, errors = errors)
    return struct(entry = entries[0], errors = [])

def sdk_pin_errors(flutter_version, sdk_pins, chosen, entries):
    """The places a build would use a package outside an SDK package's exact pin.

    Flutter's own packages depend on a few hosted packages at exactly one version
    (`flutter_test` on `test_api 0.7.12`). pub honours that for any app that uses
    them, but the build has one copy of each package and takes the highest any
    lock records, so a lock that brings a higher one (whatever its
    `on_version_conflict`) would build the SDK package against a version it
    forbids.

    Args:
        flutter_version: The Flutter version that builds the SDK packages.
        sdk_pins: Its exact pins: SDK package name to a dict of package name
            to pinned version.
        chosen: Package name to the entry the build uses.
        entries: Package name to the entries of every lock that lists it.

    Returns:
        The messages, in a stable order; empty when every pin holds.
    """
    errors = []
    for sdk_package in sorted(sdk_pins.keys()):
        if sdk_package not in chosen:
            continue
        for package, pin in sorted(sdk_pins[sdk_package].items()):
            winner = chosen.get(package)
            if winner == None or winner.kind != HOSTED or winner.version == pin:
                continue
            bringing = [e for e in entries[package] if e.version == winner.version]
            errors.append((
                "The Flutter SDK package \"{sdk}\" (Flutter {flutter}) depends on \"{package}\" at exactly {pin}, " +
                "but this build would use {version}, which {where} records.\n" +
                "rules_flutter builds one version of each package and the SDK's pin is not negotiable: " +
                "re-resolve {that} so it holds \"{package}\" at {pin}, " +
                "for example by adding `{package}: {pin}` to its pubspec's dependencies."
            ).format(
                sdk = sdk_package,
                flutter = flutter_version,
                package = package,
                pin = pin,
                version = winner.version,
                where = " and ".join(sorted({"hub \"{}\", {}".format(e.hub, e.lock_label): True for e in bringing}.keys())),
                that = "that lock" if len(bringing) == 1 else "those locks",
            ))
    return errors

def unsupported_locks(entries):
    """The locks that list an unsupported package, for its one stub's message.

    Args:
        entries: The package's entries, of kind `UNSUPPORTED`.

    Returns:
        The lock labels, joined.
    """
    return ", ".join(sorted({e.lock_label: True for e in entries if e.kind == UNSUPPORTED}.keys()))
