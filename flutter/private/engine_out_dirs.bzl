"""Reading an engine checkout's out dirs: their names, their `args.gn`, and which one serves a slot.

`engine/src/flutter/tools/gn` names an out dir `<target_os | host | wasm>_<runtime
mode>[_sim][_unopt][_<cpu>]`, appending the CPU only when it differs from that
platform's default (see docs/design/design_custom_engine.md, section 7.1). A
name is only how the scan finds candidates: `args.gn` is the authority on what
a directory holds.
"""

_MODES = ["debug", "profile", "release"]
_CPUS = ["arm", "arm64", "x64", "x86", "riscv64", "loong64"]
_OSES = ["host", "wasm", "mac", "ios", "android", "linux", "win", "fuchsia"]

# The CPU a name means when it states none.
_DEFAULT_CPU = {
    "android": "arm",
    "mac": "x64",
    "host": "x64",
    "linux": "x64",
    "win": "x64",
    "ios": "arm64",
    "wasm": "wasm",
    "fuchsia": "x64",
}

def parse_out_dir_name(name):
    """Parses the name `tools/gn` gives an out dir.

    Args:
        name: The directory's name.

    Returns:
        `struct(name, os, mode, sim, unopt, cpu)`, or None for a name the grammar does not produce
        (a `--target-dir`, a sanitizer build).
    """
    tokens = name.split("_")
    if len(tokens) < 2 or tokens[0] not in _OSES or tokens[1] not in _MODES:
        return None
    os = tokens[0]
    rest = tokens[2:]
    sim = bool(rest) and rest[0] == "sim"
    if sim:
        rest = rest[1:]
    unopt = bool(rest) and rest[0] == "unopt"
    if unopt:
        rest = rest[1:]
    cpu = _DEFAULT_CPU[os]
    if os == "ios" and sim:
        cpu = "x64"
    if rest:
        if len(rest) > 1 or rest[0] not in _CPUS:
            return None
        cpu = rest[0]
    return struct(name = name, os = os, mode = tokens[1], sim = sim, unopt = unopt, cpu = cpu)

def parse_args_gn(text):
    """Reads the `key = value` lines of an `args.gn`.

    Args:
        text: The file's text.

    Returns:
        A dict from key to value; a quoted string is unquoted, anything else
        (`true`, a number) is kept as written.
    """
    args = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value.startswith("\"") and value.endswith("\""):
            value = value[1:-1]
        args[key.strip()] = value
    return args

def effective_cpu(parsed, args):
    """The CPU an out dir was generated for: `args.gn` says, the name is the fallback."""
    return args.get("target_cpu") or parsed.cpu

def out_dir_names(os_names, mode, cpu):
    """The names an out dir for a slot can have, for a message.

    Args:
        os_names: The target OS prefixes that can hold it (`host`, `mac`).
        mode: The runtime mode.
        cpu: The CPU wanted.

    Returns:
        The names, `host_release_arm64` and `host_release_unopt_arm64` and so on.
    """
    names = []
    for os in os_names:
        for unopt in ["", "_unopt"]:
            names.append("{}_{}{}_{}".format(os, mode, unopt, cpu))
    return names

def select_out_dir(candidates, os_names, mode, cpu, pins):
    """Chooses the out dir that serves one slot.

    A mode with no out dir is not served by another mode's: the modes are not
    interchangeable at run time. Optimised and unoptimised are the user's
    choice, never a preference: both present is an ambiguity to pin.

    Args:
        candidates: A list of `struct(name, os, mode, sim, unopt, cpu)` whose
            `cpu` is the effective one.
        os_names: The target OS prefixes that can hold the slot.
        mode: The runtime mode.
        cpu: The CPU wanted.
        pins: Out dir names the user chose (`FLUTTER_LOCAL_ENGINES`); empty for none.

    Returns:
        `struct(name, error)`: the chosen directory's name, or None and why not.
    """
    matches = [c.name for c in candidates if c.os in os_names and c.mode == mode and c.cpu == cpu and not c.sim]
    if pins:
        matches = [n for n in matches if n in pins]
    if len(matches) == 1:
        return struct(name = matches[0], error = None)
    if not matches:
        return struct(name = None, error = "no out dir {} found for {} on {}".format(
            ", ".join(out_dir_names(os_names, mode, cpu)),
            mode,
            cpu,
        ))
    return struct(name = None, error = (
        "{count} out dirs fit {mode} on {cpu}: {names}. Pick one with FLUTTER_LOCAL_ENGINES, " +
        "for example FLUTTER_LOCAL_ENGINES={first}"
    ).format(count = len(matches), mode = mode, cpu = cpu, names = ", ".join(matches), first = matches[0]))
