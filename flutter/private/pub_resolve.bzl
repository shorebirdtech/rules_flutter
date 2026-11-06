"""Mapping a lock's packages to the workspace targets that stand for them.

`flutter.pub(resolve = {name: label})` names, for a package of the lock, the
target in the user's repository that builds it. A `path:` dependency's files are
already in the repository, so every `path` entry of the lock must be mapped. A
hosted, git or sdk entry may be mapped too, to replace the locked package for
the whole graph with a fork or a patched copy: the hub's label for the package
is the target, so a hosted package that depends on it gets it, and the locked
package is not fetched.

Where a `path` entry points is pub's concern only: the map already says where
Bazel gets the package, which may be another module (a sibling checkout pub
reads by path and Bazel takes from a `bazel_dep`). What holds the mapping to the
lock is that the target declares the package's name, checked at analysis
(`resolved_package.bzl`).

The checks here are pure and run when the extension reads the lock, so a wrong
map fails every Bazel command that loads the module, naming the lock, the
package and the fix. Every function returns messages and never calls `fail`:
a unit test cannot catch `fail`.
"""

def path_package_dir(lock_package, path):
    """Resolves a `path` lock entry's path to the Bazel package it names.

    The path is relative to the directory of the lock, whatever the depth of the
    package that declared the dependency. Both `/` and `\\` separate segments.

    Args:
        lock_package: The Bazel package of the lock; empty for the repository root.
        path: The `path` of the entry's `description`.

    Returns:
        `struct(dir, error)`: `dir`, the Bazel package (empty for the
        repository root), or None when `error` is set: the path leaves the
        repository.
    """
    segments = []
    for segment in (lock_package + "/" + path.replace("\\", "/")).split("/"):
        if segment == "" or segment == ".":
            continue
        if segment == "..":
            if not segments:
                return struct(dir = None, error = "leaves the repository")
            segments.pop()
        else:
            segments.append(segment)
    return struct(dir = "/".join(segments), error = None)

def _is_true(value):
    return value in ["true", "True"]

def _target(dir):
    return "//{}:<target>".format(dir)

def _path_package_errors(lock, hub, name, info, resolve):
    """The mistakes in one `path` entry's mapping."""
    description = info.get("description", {})
    path = description.get("path", "") if type(description) == "dict" else ""
    relative = type(description) == "dict" and _is_true(description.get("relative", ""))
    resolved = path_package_dir(lock.package, path)

    if name not in resolve:
        if relative and resolved.dir != None:
            suggestion = '    resolve = {{"{name}": "{target}"}},'.format(name = name, target = _target(resolved.dir))
        else:
            suggestion = '    resolve = {{"{name}": "//<package>:<target>"}},'.format(name = name)
        return [
            ("{lock} lists \"{name}\" from path \"{path}\", which flutter.pub(name = \"{hub}\") maps to no target. " +
             "Add the target that builds it to resolve:\n{suggestion}").format(
                lock = str(lock),
                name = name,
                path = path,
                hub = hub,
                suggestion = suggestion,
            ),
        ]

    return []

def resolve_errors(lock, hub, lock_pkgs, resolve):
    """Everything wrong with how `flutter.pub(resolve = ...)` maps the lock's packages.

    Args:
        lock: The lock's `Label`.
        hub: The hub's name, for messages.
        lock_pkgs: The lock's packages, from `parse_pubspec_lock`.
        resolve: The tag's `resolve`: package name to the target's `Label`.

    Returns:
        The messages, in a stable order; empty when the map is valid.
    """
    errors = []
    for name in sorted(lock_pkgs.keys()):
        info = lock_pkgs[name]
        if info.get("source", "unknown") == "path":
            errors.extend(_path_package_errors(lock, hub, name, info, resolve))

    for name in sorted(resolve.keys()):
        if name not in lock_pkgs:
            errors.append(
                ("flutter.pub(name = \"{hub}\") maps \"{name}\" in resolve, but {lock} does not list it. " +
                 "Remove it from resolve, or re-resolve the lock: bazel run @rules_flutter//flutter:pub -- get").format(
                    hub = hub,
                    name = name,
                    lock = str(lock),
                ),
            )
    return errors
