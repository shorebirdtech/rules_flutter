"""Which Flutter version a `flutter.toolchain` name resolves to."""

def parse_flutter_version(v):
    """Splits a version string into a list of ints for comparison.

    Args:
        v: A dotted version such as `3.47.9`.

    Returns:
        The components as ints.
    """
    result = []
    for x in v.split("."):
        if not x.isdigit():
            fail((
                "Invalid Flutter version '{}': expected numeric components " +
                "separated by dots (e.g. '3.47.2'), but got non-numeric component '{}'."
            ).format(v, x))
        result.append(int(x))
    return result

def select_flutter_version(root_version, versions):
    """The version a toolchain name gets.

    The root module chooses, as it chooses every toolchain: its tag wins over
    any a dependency declares. A name the root does not declare takes the
    highest version the other modules ask for.

    Args:
        root_version: The root module's version for the name, or None.
        versions: Every module's version for the name, the root's included.

    Returns:
        The selected version.
    """
    if root_version != None:
        return root_version
    selected = versions[0]
    for v in versions[1:]:
        if parse_flutter_version(v) > parse_flutter_version(selected):
            selected = v
    return selected
