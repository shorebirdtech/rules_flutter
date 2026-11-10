"""The `pub` extension's root-only statements: `flutter_pub.settings` and ignored hooks."""

def root_only_settings(modules):
    """The root's `flutter_pub.settings` and ignored hooks, refusing either from any other module.

    How the build's version choices are reported is the root's to decide, as
    is whether a hook matters: that depends on the programs the build makes,
    which are the root's. Pure, so a unit test reads the error.

    Args:
      modules: The extension's modules (`module_ctx.modules`).

    Returns:
      `struct(check, ignore_hooks, error)`: the root's level for its raised
      requests, the packages whose hooks the root declared irrelevant, and the
      message refusing the statements, None when there is none.
    """
    check = "warning"
    ignore_hooks = {}
    for mod in modules:
        if not mod.is_root:
            if mod.tags.settings:
                return struct(check = check, ignore_hooks = {}, error = (
                    "Module `%s` uses `flutter_pub.settings`, which only the root module may use: " +
                    "how the build's version choices are reported is the root's to decide. " +
                    "Remove it from that module."
                ) % mod.name)
            hooks = []
            for lock_tag in mod.tags.from_lock:
                hooks.extend(lock_tag.ignore_hooks)
            if hooks:
                return struct(check = check, ignore_hooks = {}, error = (
                    "Module `%s` ignores the build hooks of %s, which only the root module " +
                    "may do: whether a hook matters depends on the programs the build makes, " +
                    "which are the root's. Remove `ignore_hooks` from that module's " +
                    "`flutter_pub.from_lock`; the root declares the hooks its programs never reach."
                ) % (mod.name, ", ".join(["`%s`" % h for h in sorted(hooks)])))
            continue
        if len(mod.tags.settings) > 1:
            return struct(check = check, ignore_hooks = {}, error = (
                "The root module uses `flutter_pub.settings` %d times; state it once."
            ) % len(mod.tags.settings))
        for settings in mod.tags.settings:
            check = settings.check_direct_dependencies
        for lock_tag in mod.tags.from_lock:
            for name in lock_tag.ignore_hooks:
                ignore_hooks[name] = True
    return struct(check = check, ignore_hooks = ignore_hooks, error = None)
