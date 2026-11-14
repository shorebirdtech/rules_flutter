"""Declares one app bundle as two targets that differ only in how it is signed."""

def signing_twin(rule, name, twin_suffix, common, base = {}, twin = {}, overrides = {}):
    """Declares `rule` as `name` and as `name + twin_suffix`.

    The two targets take the same attributes, `common` with `overrides` laid
    over it, and differ in `base` for the first and `twin` for the second. The
    twin also gets `bundle_name = name`: a bundle is named after its target by
    default, and an app embedding its extensions expects one name in
    `Contents/PlugIns/` or `PlugIns/` whichever twin it takes.

    rules_apple signs each bundle in its own target, so the app's provisioning
    profile does not reach an extension. An example that shows both a build
    with no profile and one signed by a team needs both targets of every
    extension.

    Args:
        rule: The rule to declare, as loaded (`ios_extension`).
        name: The first target's name.
        twin_suffix: Appended to `name` for the second target's name.
        common: Attributes of both targets.
        base: Attributes of the first target only.
        twin: Attributes of the second target only.
        overrides: Attributes the caller chose, which replace `common`'s.
    """
    shared = dict(common)
    shared.update(overrides)
    for attr in base.keys() + twin.keys() + ["bundle_name"]:
        if attr in shared:
            fail("%s: `%s` is set per target by the twin, so it cannot also be common or passed in" % (name, attr))
    rule(name = name, **(shared | base))
    rule(name = name + twin_suffix, bundle_name = name, **(shared | twin))
