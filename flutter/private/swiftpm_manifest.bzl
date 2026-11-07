"""What rules_flutter reads from a pub plugin's `Package.swift`.

rules_flutter compiles a plugin's own sources, not a SwiftPM build. Two parts
of the manifest change what those sources become, and rules_flutter supplies
neither, so the caller fails on each rather than build a different plugin.

Dependencies. A pub plugin whose Apple side is a SwiftPM package lists what it
needs from other packages in `dependencies:`:

    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(path: "../shared"),
    ],

rules_flutter does not resolve other Swift packages. A remote dependency would
be missing from the build and the app would fail to compile or crash at
runtime, so `find_unsupported_swiftpm_dependencies` reports each one. A
dependency on a directory inside the plugin is fine: its sources are part of
the plugin. A directory outside the plugin is not.

Build settings. `.define` and `.unsafeFlags` in a target's `cSettings`,
`cxxSettings` or `swiftSettings` set preprocessor macros and compiler flags.
A manifest can compute them: `permission_handler_apple` reads the app's
`Info.plist` and enables a permission's code only when the plist declares its
usage description, so built without its defines every permission reports
`denied`, and nothing fails. `find_swiftpm_build_settings` reports each one.
"""

def _strip_comments(text):
    """Returns `text` without `//` and `/* */` comments, leaving strings alone."""
    out = []
    i = 0
    n = len(text)
    quote = None
    for _ in range(n * 2 + 1):
        if i >= n:
            break
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
        elif c == '"':
            quote = c
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)

def _call_arguments(text, start):
    """Returns the text between the parenthesis opened at `start` and its match."""
    depth = 0
    quote = None
    i = start
    n = len(text)
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c == '"':
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return text[start + 1:]

def _string_argument(args, label):
    """The string literal after top-level `label:` in `args`, or None."""
    marker = label + ":"
    quote = None
    depth = 0
    i = 0
    n = len(args)
    for _ in range(n + 1):
        if i >= n:
            break
        c = args[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c == '"':
            quote = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif depth == 0 and args.startswith(marker, i) and (i == 0 or not (args[i - 1].isalnum() or args[i - 1] == "_")):
            rest = args[i + len(marker):].lstrip()
            if rest.startswith('"'):
                end = rest.find('"', 1)
                if end > 0:
                    return rest[1:end]
            return ""
        i += 1
    return None

def _escapes(base_dir, path):
    """Whether `path`, taken relative to `base_dir` inside the plugin, leaves it."""
    if path.startswith("/") or path.startswith("~"):
        return True
    parts = [p for p in base_dir.split("/") if p and p != "."]
    for seg in path.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not parts:
                return True
            parts.pop()
        else:
            parts.append(seg)
    return False

def find_unsupported_swiftpm_dependencies(content, package_dir):
    """Finds the `.package(...)` dependencies of a `Package.swift` that cannot be met.

    Args:
        content: The text of the `Package.swift`.
        package_dir: The directory holding it, relative to the plugin's root
            (`ios/foo`), which local `path:` dependencies are resolved against.

    Returns:
        A list of strings, one per dependency: the URL of a remote package
        (`url:`, or a registry `id:`), or `path <path>` for a local one that
        lies outside the plugin.
    """
    text = _strip_comments(content)
    found = []
    marker = ".package("
    pos = 0
    for _ in range(len(text) + 1):
        at = text.find(marker, pos)
        if at < 0:
            break
        open_at = at + len(marker) - 1
        args = _call_arguments(text, open_at)
        pos = open_at + 1
        url = _string_argument(args, "url")
        pkg_id = _string_argument(args, "id")
        path = _string_argument(args, "path")
        if url != None:
            found.append(url)
        elif pkg_id != None:
            found.append("registry package " + pkg_id)
        elif path != None and _escapes(package_dir, path):
            found.append("path " + path)
    return found

def _top_level_arguments(args):
    """Splits a call's argument text at its top-level commas, trimmed."""
    parts = []
    depth = 0
    quote = None
    start = 0
    i = 0
    n = len(args)
    for _ in range(n + 1):
        if i >= n:
            break
        c = args[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c == '"':
            quote = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(args[start:i])
            start = i + 1
        i += 1
    parts.append(args[start:])
    return [_collapse_whitespace(p) for p in parts if p.strip()]

def _collapse_whitespace(text):
    """`text` with each run of whitespace outside strings made one space."""
    out = []
    quote = None
    space = False
    i = 0
    n = len(text)
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in " \t\n\r":
            space = True
        else:
            if space and out:
                out.append(" ")
            space = False
            if c == '"':
                quote = c
            out.append(c)
        i += 1
    return "".join(out).strip()

def _describe_define(args):
    """`define NAME`, `define NAME = <value>`, and any condition after them."""
    parts = _top_level_arguments(args)
    if not parts:
        return "define()"
    name = parts[0]
    if len(name) >= 2 and name.startswith('"') and name.endswith('"'):
        name = name[1:-1]
    text = "define " + name
    for part in parts[1:]:
        if part.startswith("to:"):
            text += " = " + part[len("to:"):].strip()
        else:
            text += ", " + part
    return text

def find_swiftpm_build_settings(content):
    """Finds the build settings of a `Package.swift` that change its compile.

    These are the `.define(...)` and `.unsafeFlags(...)` settings, wherever the
    manifest writes them: in a target's `cSettings`, `cxxSettings` or
    `swiftSettings`, or in a list it builds first and adds to them. Header
    search paths and linker settings are not reported: a missing one fails
    the compile or the link by itself.

    Args:
        content: The text of the `Package.swift`.

    Returns:
        A list of strings, one per setting, in manifest order:
        `define NAME`, `define NAME = <value as written>` (a value may be an
        expression the manifest computes), with any condition after a comma,
        or `unsafeFlags(<arguments>)`.
    """
    text = _strip_comments(content)
    found = []
    pos = 0
    for _ in range(len(text) + 1):
        define_at = text.find(".define(", pos)
        flags_at = text.find(".unsafeFlags(", pos)
        if define_at < 0 and flags_at < 0:
            break
        if flags_at < 0 or (define_at >= 0 and define_at < flags_at):
            open_at = define_at + len(".define(") - 1
            args = _call_arguments(text, open_at)
            found.append(_describe_define(args))
        else:
            open_at = flags_at + len(".unsafeFlags(") - 1
            args = _call_arguments(text, open_at)
            found.append("unsafeFlags(%s)" % _collapse_whitespace(args))
        pos = open_at + len(args) + 2
    return found

def build_settings_message(package, version, platform, manifest, settings):
    """Why the `platform` build of an app linking `package` stops, and what to do.

    Args:
        package: The pub package's name.
        version: Its version.
        platform: `"ios"` or `"macos"`.
        manifest: The manifest that sets the settings, relative to the plugin's root.
        settings: What `find_swiftpm_build_settings` found in it.

    Returns:
        The message.
    """
    return (
        "package:{pkg} {version} sets build settings in {manifest} that rules_flutter " +
        "does not supply:\n    {settings}\n" +
        "rules_flutter compiles the plugin's sources without evaluating its manifest, " +
        "and a plugin built without its settings can compile and still behave " +
        "differently (permission_handler_apple, for one, reports every permission as " +
        "denied), so the {platform} build stops here. Give {pkg} a plugin overlay " +
        "(`flutter_pub.plugin_overlays` in MODULE.bazel) whose " +
        "`flutter_apple_plugin_library` sets what your app needs, a define as `-D<NAME>` " +
        "in `copts`. See \"Apple plugins that set build settings\" in rules_flutter's README."
    ).format(
        pkg = package,
        version = version,
        manifest = manifest,
        settings = "\n    ".join(settings),
        platform = {"ios": "iOS", "macos": "macOS"}[platform],
    )
