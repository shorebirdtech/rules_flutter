"""Maven dependencies of pub plugins' Android Gradle builds.

A pub plugin's `android/build.gradle(.kts)` declares the Maven artifacts its
Kotlin/Java sources compile against. The app's Android Maven classpath is one
`rules_jvm_external` resolution, `@rules_android_maven`, so that Coursier picks
one version of every artifact for the whole app (the highest, as Gradle does).
A plugin's declared artifacts therefore have to come from that repo.

This file holds the pieces:

* `parse_gradle_maven_dependencies` reads the declarations out of a script.
* `merge_plugin_requirements` and `maven_problems` merge what every plugin of
  a hub declares and compare it with what `@rules_android_maven` resolved.
* `flutter_android_maven` is a repository rule, one per hub, that gathers what
  every plugin declares and what `@rules_android_maven` resolved. It writes
  a `requirements` target, which an application's `flutter_android_plugin_libs`
  reads to check the plugins that application links (and those only),
  `resolved.bzl`, which a plugin's `android/` package
  loads to depend on the artifacts that exist, and a `maven_artifacts` target
  that prints the complete block for the root module's `maven.install`.

Only an Android build that links a plugin reads any of this, so only such a
build fetches it.
"""

# Where each spoke records what its Gradle build declares, at the spoke's root.
MAVEN_DEPS_FILE = "flutter_android_maven_deps.json"

# Gradle configurations by what they mean for a plugin's compile classpath.
_KIND_BY_CONFIGURATION = {
    "implementation": "deps",
    "api": "deps",
    "compile": "deps",
    "compileOnly": "compile_only",
    "provided": "compile_only",
    "runtimeOnly": "runtime",
}

# Not part of the plugin's own classpath in an app build.
_IGNORED_PREFIXES = ("test", "androidTest", "testFixtures", "lint")
_IGNORED_CONFIGURATIONS = ("classpath",)

# Configurations the parser cannot honour.
_UNSUPPORTED_CONFIGURATIONS = (
    "kapt",
    "ksp",
    "annotationProcessor",
    "coreLibraryDesugaring",
)
_VARIANTS = ("debug", "release", "profile")
_VARIANT_SUFFIXES = ("Implementation", "Api", "CompileOnly", "RuntimeOnly")

_IDENT_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

def _leading_identifier(line):
    end = 0
    for c in line.elems():
        if c not in _IDENT_CHARS:
            break
        end += 1
    return line[:end]

def _strip_line_comment(line):
    """Cuts a `//` comment that is not inside a string literal."""
    quote = ""
    for i in range(len(line)):
        c = line[i]
        if quote:
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
        elif c == "/" and line[i + 1:i + 2] == "/":
            return line[:i]
    return line

def _matching_brace(line, start):
    """Index of the `}` that closes the `{` at `start`, or -1; quotes are skipped."""
    depth = 0
    quote = ""
    for i in range(start, len(line)):
        c = line[i]
        if quote:
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1

def _opens_a_closure(header):
    """Whether a `{` after `header` configures a dependency, not opens a block.

    `implementation("a:b:1") { exclude(group = "x") }` is one statement: the
    braces are the dependency's own closure. `dependencies {`, `if (flag) {`
    and `kapt {` open blocks, whose contents are statements of their own.
    """
    header = header.strip()
    identifier = _leading_identifier(header)
    if not identifier or (identifier != "add" and not _classify(identifier)):
        return False
    rest = header[len(identifier):]
    return bool(rest.strip()) and rest[0] in " \t('\"" and not rest.strip().startswith("=")

def _split_statements(line, out):
    """Appends the statements of one physical line of a Gradle script to `out`.

    A line holds several when a block is opened and closed on it (`dependencies
    { implementation 'a:b:1' }`) or `;` separates them. Braces, brackets and
    parentheses inside a string or inside a call's arguments never split, and
    the closure of a dependency declaration stays with it (see
    `_opens_a_closure`), so the declaration is reported whole if it is not one
    the reader supports.
    """
    cur = ""
    quote = ""
    depth = 0
    i = 0
    n = len(line)
    for _ in range(n + 1):
        if i >= n:
            break
        c = line[i]
        if quote:
            cur += c
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
            cur += c
        elif c == "(" or c == "[":
            depth += 1
            cur += c
        elif c == ")" or c == "]":
            depth = max(depth - 1, 0)
            cur += c
        elif depth == 0 and c == "{" and _opens_a_closure(cur):
            close = _matching_brace(line, i)
            end = n if close < 0 else close + 1
            cur += line[i:end]
            i = end
            continue
        elif depth == 0 and c in ";{}":
            if cur.strip():
                out.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        out.append(cur.strip())

def gradle_statements(content):
    """The statements of a Gradle build script, comments removed.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.

    Returns:
        A list of stripped strings, one per statement or block header.
    """
    out = []
    for raw in content.split("\n"):
        _split_statements(_strip_line_comment(raw), out)
    return out

def _string_literal(text):
    """The value of `text` when it is exactly one string literal, else None."""
    text = text.strip()
    if len(text) < 2:
        return None
    q = text[0]
    if q != "'" and q != '"':
        return None
    if text[-1] != q:
        return None
    inner = text[1:-1]
    if q in inner:
        return None
    return inner

def _variable_definition(line):
    """`(name, value)` when `line` defines a string variable, else None."""
    name = ""
    rest = ""
    for prefix in ("def ", "val ", "var ", "String ", "final String "):
        if line.startswith(prefix):
            rest = line[len(prefix):].strip()
            name = _leading_identifier(rest)
            rest = rest[len(name):].strip()
            if rest.startswith(":"):
                rest = rest[1:].strip()
                type_name = _leading_identifier(rest)
                if type_name != "String":
                    return None
                rest = rest[len(type_name):].strip()
            break
    if not name:
        if line.startswith("ext."):
            rest = line[len("ext."):]
            name = _leading_identifier(rest)
            rest = rest[len(name):].strip()
        elif line.startswith("ext[") and line[4:5] in ("'", '"'):
            q = line[4]
            close = line.find(q + "]", 5)
            if close < 0:
                return None
            name = line[5:close]
            rest = line[close + 2:].strip()
    if not name or not rest.startswith("="):
        return None
    value = _string_literal(rest[1:])
    if value == None:
        return None
    return (name, value)

def _substitute_version(version, variables):
    """Replaces `$name` / `${name}`; None when any is unknown."""
    if "$" not in version:
        return version
    out = ""
    i = 0
    n = len(version)
    for _ in range(n + 1):
        if i >= n:
            break
        c = version[i]
        if c != "$":
            out += c
            i += 1
            continue
        if version[i + 1:i + 2] == "{":
            close = version.find("}", i + 2)
            if close < 0:
                return None
            name = version[i + 2:close]
            i = close + 1
        else:
            name = _leading_identifier(version[i + 1:])
            i += 1 + len(name)
        if not name or name not in variables:
            return None
        out += variables[name]
    return out

def _is_dynamic(version):
    if "+" in version or version.startswith("latest."):
        return True
    for c in "[](),".elems():
        if c in version:
            return True
    return False

def _classify(identifier):
    """A dependency kind, `"ignore"`, `"error"`, or `""` for anything else."""
    if identifier in _KIND_BY_CONFIGURATION:
        return _KIND_BY_CONFIGURATION[identifier]
    if identifier in _IGNORED_CONFIGURATIONS:
        return "ignore"
    for p in _IGNORED_PREFIXES:
        if identifier.startswith(p):
            return "ignore"
    if identifier in _UNSUPPORTED_CONFIGURATIONS:
        return "error"
    for v in _VARIANTS:
        if identifier.startswith(v):
            for s in _VARIANT_SUFFIXES:
                if identifier == v + s:
                    return "error"
    return ""

def _applies_a_script(rest):
    """Whether the arguments after `apply` name a script: `from: "x"` / `from = "x"`."""
    rest = rest.strip()
    if rest.startswith("("):
        rest = rest[1:].strip()
    return rest.startswith("from") and rest[4:5] in (":", " ", "=")

def _add_call_as_declaration(line):
    """`add("implementation", "a:b:1")` as `implementation("a:b:1")`.

    Anything else (a configuration that is not a dependency one, or a first
    argument that is not a string) is returned as `add`, which the caller
    does not treat as a declaration.
    """
    rest = line[len("add"):].strip()
    if not rest.startswith("(") or not rest.endswith(")"):
        return line
    inner = rest[1:-1]
    comma = -1
    quote = ""
    for i in range(len(inner)):
        c = inner[i]
        if quote:
            if c == quote:
                quote = ""
        elif c == "'" or c == '"':
            quote = c
        elif c == ",":
            comma = i
            break
    if comma < 0:
        return line
    configuration = _string_literal(inner[:comma])
    if configuration == None or not _classify(configuration):
        return line
    return configuration + "(" + inner[comma + 1:].strip() + ")"

def parse_gradle_maven_dependencies(content):
    """Reads the Maven dependencies out of a Gradle build script.

    Statement based (see `gradle_statements`: a line can hold several, and a
    block opened and closed on one line is read like one spread over many).
    Each dependency must be exactly one string literal of the form
    `group:artifact:version` (a `:classifier` and an `@packaging` are allowed
    and dropped), declared as `implementation "..."`, `implementation("...")`
    or `add("implementation", "...")`. Anything else that is a dependency on
    the plugin's compile or runtime classpath, and an `apply from:` that pulls
    in statements this reader never sees, is reported in `errors`, so a
    dependency the parser cannot read is never silently lost.

    Args:
        content: The text of `build.gradle` or `build.gradle.kts`.

    Returns:
        A struct. `deps` is a list of structs with `kind` (`"deps"`,
        `"compile_only"` or `"runtime"`), `group`, `artifact`, `version` (a
        string, or None when it is a variable the file does not define or a
        dynamic version, which get a presence-only check) and `line`.
        `errors` is the list of lines that could not be read.
    """
    lines = gradle_statements(content)

    variables = {}
    for line in lines:
        d = _variable_definition(line)
        if d:
            variables[d[0]] = d[1]

    deps = []
    errors = []
    for original in lines:
        line = original
        identifier = _leading_identifier(line)
        if not identifier:
            continue

        # `apply from: "deps.gradle"` pulls in statements this reader never
        # sees, so it is reported rather than followed.
        if identifier == "apply" and _applies_a_script(line[len(identifier):]):
            errors.append(original)
            continue

        # `add("implementation", "a:b:1")` is `implementation("a:b:1")`.
        if identifier == "add":
            line = _add_call_as_declaration(line)
            identifier = _leading_identifier(line)
            if not identifier:
                continue
        kind = _classify(identifier)
        if not kind or kind == "ignore":
            continue
        rest = line[len(identifier):]

        # `implementation = ...`, `kapt { ... }` and `api.foo` configure
        # something else; a dependency is followed by an argument.
        if not rest or rest[0] not in " \t('\"":
            continue
        rest = rest.strip()
        if not rest or rest[0] == "=" or rest[0] == "{":
            continue
        if kind == "error":
            errors.append(original)
            continue

        arg = rest
        if arg.startswith("("):
            if not arg.endswith(")"):
                errors.append(original)
                continue
            arg = arg[1:-1]
        coordinate = _string_literal(arg)
        if coordinate == None:
            errors.append(original)
            continue
        coordinate = coordinate.split("@")[0]
        parts = coordinate.split(":")
        if len(parts) < 3 or len(parts) > 4 or not parts[0] or not parts[1] or not parts[2]:
            errors.append(original)
            continue
        group = parts[0]
        artifact = parts[1]
        if group == "io.flutter":
            continue
        if group == "org.jetbrains.kotlin" and artifact.startswith("kotlin-stdlib"):
            continue
        version = _substitute_version(parts[2], variables)
        if version != None and _is_dynamic(version):
            version = None
        deps.append(struct(
            kind = kind,
            group = group,
            artifact = artifact,
            version = version,
            line = original,
        ))
    return struct(deps = deps, errors = errors)

def maven_target_name(group, artifact):
    """rules_jvm_external's target name for `group:artifact`.

    Args:
        group: The Maven group.
        artifact: The Maven artifact id.

    Returns:
        The name of the target `@rules_android_maven` gives the artifact.
    """
    name = group + ":" + artifact
    for c in ".-:/+$".elems():
        name = name.replace(c, "_")
    return name

# Qualifier order, as Maven's ComparableVersion: alpha < beta < milestone <
# rc < snapshot < release < sp. Unknown qualifiers sort after all of these.
_QUALIFIER_RANK = {
    "alpha": 0,
    "a": 0,
    "beta": 1,
    "b": 1,
    "milestone": 2,
    "m": 2,
    "rc": 3,
    "cr": 3,
    "snapshot": 4,
    "": 5,
    "ga": 5,
    "final": 5,
    "release": 5,
    "sp": 6,
}
_RELEASE_RANK = 5
_UNKNOWN_RANK = 7

def _version_tokens(version):
    """Splits on `.`, `-` and digit/letter transitions.

    Each token is `(True, int)` or `(False, qualifier)`.
    """
    tokens = []
    current = ""
    current_numeric = False
    for c in version.lower().elems():
        if c == "." or c == "-" or c == "_":
            if current:
                tokens.append((current_numeric, current))
            current = ""
            continue
        numeric = c.isdigit()
        if current and numeric != current_numeric:
            tokens.append((current_numeric, current))
            current = ""
        current += c
        current_numeric = numeric
    if current:
        tokens.append((current_numeric, current))
    return [(True, int(t)) if numeric else (False, t) for numeric, t in tokens]

def _qualifier_key(qualifier):
    rank = _QUALIFIER_RANK.get(qualifier)
    if rank == None:
        return (_UNKNOWN_RANK, qualifier)
    return (rank, "")

def _cmp(x, y):
    return 1 if x > y else (-1 if x < y else 0)

def _compare_present(a, b):
    """Compares token `a` with `b`, which may be None (absent)."""
    if a[0]:
        if b == None:
            return 0 if a[1] == 0 else 1
        if b[0]:
            return _cmp(a[1], b[1])
        return 1
    ka = _qualifier_key(a[1])
    if b == None:
        kb = (_RELEASE_RANK, "")
    elif b[0]:
        return -1
    else:
        kb = _qualifier_key(b[1])
    return _cmp(ka, kb)

def _compare_tokens(a, b):
    """Compares two tokens, either of which may be None (absent)."""
    if a == None and b == None:
        return 0
    if a == None:
        return -_compare_present(b, None)
    return _compare_present(a, b)

def compare_maven_versions(a, b):
    """Orders two Maven version strings, as Maven's ComparableVersion.

    Simplified: tokens split on `.`/`-` and digit/letter transitions; numbers
    compare numerically with missing ones as 0; qualifiers order
    alpha < beta < milestone < rc < snapshot < release < sp, unknown ones
    after, lexically.

    Args:
        a: A version.
        b: Another version.

    Returns:
        -1, 0 or 1.
    """
    ta = _version_tokens(a)
    tb = _version_tokens(b)
    for i in range(max(len(ta), len(tb))):
        c = _compare_tokens(
            ta[i] if i < len(ta) else None,
            tb[i] if i < len(tb) else None,
        )
        if c != 0:
            return c
    return 0

def maven_labels(declared, resolved = None):
    """The `@rules_android_maven` labels of a plugin's declared artifacts.

    Args:
        declared: List of dicts with `kind` (`"deps"`, `"compile_only"`,
            `"runtime"`) and `coordinate` (`group:artifact`).
        resolved: Dict of `group:artifact` to the version `@rules_android_maven`
            resolved, or None for every artifact. An artifact it lacks has no
            target to depend on, so one not in `resolved` is left out.

    Returns:
        A struct with the label lists `deps`, `compile_only` and
        `runtime_deps`, without duplicates.
    """
    labels = {"deps": [], "compile_only": [], "runtime": []}
    for d in declared:
        if resolved != None and d["coordinate"] not in resolved:
            continue
        group, artifact = d["coordinate"].split(":")[:2]
        label = "@rules_android_maven//:" + maven_target_name(group, artifact)
        if label not in labels[d["kind"]]:
            labels[d["kind"]].append(label)
    return struct(
        deps = labels["deps"],
        compile_only = labels["compile_only"],
        runtime_deps = labels["runtime"],
    )

def merge_plugin_requirements(packages):
    """The version each Maven artifact must have for every plugin of a hub.

    Args:
        packages: List of dicts with `package`, `version` and `deps`, the
            latter dicts with `coordinate` (`group:artifact`) and `version`
            (a string, or None for a declaration that names no usable one).

    Returns:
        A dict of coordinate to a dict with `version` (the highest declared,
        or None when no plugin names one) and `declared_by`, the list of
        `package:<name> <version>` strings of the plugins that declare it.
    """
    requirements = {}
    for pkg in packages:
        label = "package:%s %s" % (pkg["package"], pkg["version"])
        for d in pkg["deps"]:
            req = requirements.setdefault(
                d["coordinate"],
                {"version": None, "declared_by": []},
            )
            if label not in req["declared_by"]:
                req["declared_by"].append(label)
            v = d["version"]
            if v != None and (req["version"] == None or compare_maven_versions(v, req["version"]) > 0):
                req["version"] = v
    return requirements

def maven_problems(requirements, resolved):
    """The requirements `@rules_android_maven` does not meet.

    Args:
        requirements: The result of `merge_plugin_requirements`.
        resolved: Dict of `group:artifact` to the version resolved.

    Returns:
        A list of dicts with `coordinate`, `version`, `declared_by` and
        `reason` (`"missing"` or `"resolves <version>"`), sorted by
        coordinate. A requirement with no version is met by any resolution.
    """
    problems = []
    for coordinate in sorted(requirements.keys()):
        req = requirements[coordinate]
        have = resolved.get(coordinate)
        if have == None:
            reason = "missing"
        elif req["version"] != None and compare_maven_versions(have, req["version"]) < 0:
            reason = "resolves " + have
        else:
            continue
        problems.append({
            "coordinate": coordinate,
            "version": req["version"],
            "declared_by": req["declared_by"],
            "reason": reason,
        })
    return problems

def maven_check_message(data, linked):
    """What an application that links `linked` plugins fails with, or "".

    Args:
        data: The decoded `maven_requirements.json` of the hub: `hub` (its
            name), `resolved` (`group:artifact` to version) and `packages`
            (each a dict of `package`, `version`, `deps` and `errors`).
        linked: The names of the packages whose Android libraries the
            application links. A package the hub records no requirements for
            needs nothing.

    Returns:
        The failure message naming only what those packages need, or the empty
        string when `@rules_android_maven` provides all of it.
    """
    packages = [p for p in data["packages"] if p["package"] in linked]
    requirements = merge_plugin_requirements(packages)
    problems = maven_problems(requirements, data["resolved"])
    errors = {
        "package:%s %s" % (p["package"], p["version"]): p["errors"]
        for p in packages
        if p["errors"]
    }
    return format_maven_failure(data["hub"], problems, errors)

def _artifact_line(coordinate, version, declared_by, note):
    return '"%s:%s",  # declared by %s%s' % (
        coordinate,
        version or "<version>",
        ", ".join(declared_by),
        "; " + note if note else "",
    )

def format_maven_failure(hub, problems, errors):
    """The message `check()` fails with.

    Args:
        hub: The pub hub's name.
        problems: The result of `maven_problems`.
        errors: Dict of `package:<name> <version>` to the Gradle lines that
            could not be read.

    Returns:
        The message, listing every problem at once.
    """
    parts = []
    if problems:
        lines = [
            _artifact_line(p["coordinate"], p["version"], p["declared_by"], p["reason"])
            for p in problems
        ]
        parts.append((
            "The Android plugins this app links from @{hub} declare Maven " +
            "dependencies that @rules_android_maven does not provide at a " +
            "high enough version:\n\n    {lines}\n\n" +
            "Gradle gives a plugin the highest version declared anywhere in " +
            "the app, and so does the single resolution behind " +
            "@rules_android_maven. Add these to the root module's " +
            '`maven.install(name = "rules_android_maven", artifacts = [...])` ' +
            "and regenerate that install's lock file:\n\n" +
            "    REPIN=1 bazel run @rules_android_maven//:pin\n\n" +
            "`bazel run @{hub}//android:maven_artifacts` prints the complete " +
            "block for every plugin of the lock."
        ).format(hub = hub, lines = "\n    ".join(lines)))
    if errors:
        groups = []
        for pkg in sorted(errors.keys()):
            groups.append("    %s\n        %s" % (pkg, "\n        ".join(errors[pkg])))
        parts.append((
            "These Gradle dependency lines cannot be translated. Each must " +
            "be a single 'group:artifact:version' string in implementation, " +
            "api, compileOnly or runtimeOnly:\n\n{groups}\n\n" +
            "Provide a plugin overlay for each package (flutter.plugin_overlays " +
            "in MODULE.bazel): <root>/<package>/BUILD.bazel.tpl for the Dart " +
            "side and <root>/<package>/android/BUILD.bazel.tpl, which " +
            "declares the plugin's Android library with its " +
            "@rules_android_maven deps. An android/BUILD.bazel.tpl is used " +
            "only beside a BUILD.bazel.tpl."
        ).format(groups = "\n".join(groups)))
    return "\n\n".join(parts)

def format_artifacts_report(hub, requirements, problems):
    """The text `bazel run @<hub>//android:maven_artifacts` prints.

    Args:
        hub: The pub hub's name.
        requirements: The result of `merge_plugin_requirements`.
        problems: The result of `maven_problems`.

    Returns:
        A block ready to paste into `artifacts = [...]`, with a header saying
        which entries are missing or too low.
    """
    reasons = {p["coordinate"]: p["reason"] for p in problems}
    lines = []
    for coordinate in sorted(requirements.keys()):
        req = requirements[coordinate]
        lines.append(_artifact_line(
            coordinate,
            req["version"],
            req["declared_by"],
            reasons.get(coordinate, ""),
        ))
    out = ["# Maven artifacts the Android plugins of @%s declare." % hub]
    if not lines:
        out.append("# None.")
    elif problems:
        out.append("# %d of %d are missing or too low in @rules_android_maven (marked)." % (len(problems), len(lines)))
    else:
        out.append("# All %d are provided by @rules_android_maven." % len(lines))
    out.append("# Paste into maven.install(name = \"rules_android_maven\", artifacts = [...]):")
    out.append("")
    out += ["        " + line for line in lines]
    return "\n".join(out) + "\n"

def _resolved_versions(build):
    """`group:artifact` to version from a rules_jvm_external repo's BUILD."""
    plain = {}
    classified = {}
    for chunk in build.split("maven_coordinates=")[1:]:
        parts = chunk.split('"')[0].split("@")[0].split(":")
        if len(parts) < 3:
            continue
        key = parts[0] + ":" + parts[1]
        versions = plain if len(parts) == 3 else classified
        if key not in versions or compare_maven_versions(parts[2], versions[key]) > 0:
            versions[key] = parts[2]

    # A classifier-less entry is the artifact itself.
    best = dict(classified)
    best.update(plain)
    return best

def _flutter_android_maven_impl(rctx):
    resolved = _resolved_versions(rctx.read(rctx.path(Label("@rules_android_maven//:BUILD"))))
    packages = [json.decode(rctx.read(rctx.path(label))) for label in rctx.attr.spokes]
    packages = [p for p in packages if p["deps"] or p["errors"]]

    # The whole hub's requirements, as an application's check reads them: it
    # picks the packages it links and no others. The hub-wide report below is
    # for finding what a lock's plugins need all at once.
    requirements_json = json.encode({
        "hub": rctx.attr.hub_name,
        "resolved": resolved,
        "packages": packages,
    })
    rctx.file("resolved.bzl", "RESOLVED = %s\n" % repr(resolved))
    requirements = merge_plugin_requirements(packages)
    problems = maven_problems(requirements, resolved)
    rctx.file("report.txt", format_artifacts_report(rctx.attr.hub_name, requirements, problems))
    rctx.file("print_report.dart", rctx.read(Label("//flutter/private/tools:print_report.dart")))
    rctx.file("BUILD.bazel", """\
load("@rules_dart//dart:defs.bzl", "dart_binary")
load("@rules_flutter//flutter/private:flutter_android_plugin_libs.bzl", "flutter_android_maven_requirements")

# What an application's `flutter_android_plugin_libs` checks the plugins it
# links against.
flutter_android_maven_requirements(
    name = "requirements",
    data = {data},
    visibility = ["//visibility:public"],
)

# Prints report.txt: every Maven artifact the hub's Android plugins declare,
# as the lines to paste into maven.install(name = "rules_android_maven").
dart_binary(
    name = "maven_artifacts",
    args = ["$(rlocationpath :report.txt)"],
    compile_mode = "exe",
    data = [":report.txt"],
    main = "print_report.dart",
    visibility = ["//visibility:public"],
    deps = ["@rules_dart//dart/runfiles"],
)
""".replace("{data}", repr(requirements_json)))

flutter_android_maven = repository_rule(
    implementation = _flutter_android_maven_impl,
    attrs = {
        "hub_name": attr.string(
            doc = "The pub hub this repo serves.",
            mandatory = True,
        ),
        "spokes": attr.label_list(
            doc = "Each built spoke's `flutter_android_maven_deps.json`.",
            allow_files = True,
        ),
    },
    doc = """The Maven requirements of a pub hub's Android plugins.

Reads the versions `@rules_android_maven` resolved and the dependencies every
spoke's Gradle build declares, and generates a `requirements` target (for an
application's check of the plugins it links), `resolved.bzl` (what a plugin's
library may depend on) and the `maven_artifacts` target (every plugin of the
lock at once). It is fetched only when an Android build links a plugin.
""",
)
