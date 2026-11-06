"""Swift package dependencies that a pub plugin's `Package.swift` declares.

A pub plugin whose Apple side is a SwiftPM package lists what it needs from
other packages in `dependencies:`:

    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(path: "../shared"),
    ],

rules_flutter compiles the plugin's own sources, not a SwiftPM build, and does
not resolve other Swift packages. A remote dependency would be missing from the
build and the app would fail to compile or crash at runtime, so
`find_unsupported_swiftpm_dependencies` reports each one for the caller to fail
on. A dependency on a directory inside the plugin is fine: its sources are part
of the plugin. A directory outside the plugin is not.
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
