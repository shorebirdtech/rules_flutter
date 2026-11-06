"""Project a pub package's `flutter:` block to the shapes rules_flutter consumes.

Reading the pubspec is rules_dart's `read_pubspec`, which loads it as pub does
and refuses what pub refuses. Its `fields` (the whole document as JSON values)
are what these functions take:

- `flutter_plugin_block` — `flutter.plugin` for plugin-spoke emission.
- `flutter_assets_block` — `flutter.{fonts,assets,shaders,uses-material-design}`
  for the asset-bundling pipeline.
- `flutter_licenses_block` — `flutter.licenses`, the files `NOTICES` appends.

Schema reference (Flutter's pubspec):

    flutter:
      uses-material-design: bool
      fonts:
        - family: <name>
          fonts:
            - asset: <path>
              weight: <int>          # optional
              style: <italic|normal> # optional
      assets:
        - <path>                     # string form
        - path: <path>               # map form (modern)
          flavors: [<flavor>, ...]
          platforms: [<platform>, ...]
          transformers:              # refused: rules_flutter does not run them
            - package: <name>
      shaders:
        - <path>                     # string form
        - path: <path>               # map form
          flavors: [<flavor>, ...]
          platforms: [<platform>, ...]
      licenses:
        - <path>                     # a file of the package, appended to NOTICES
      plugin:
        implements: <umbrella>
        platforms:
          <platform>:
            pluginClass: <Class>
            ...
"""

def flutter_block(fields):
    """Return the `flutter:` sub-dict, or empty dict when absent.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        The `flutter:` mapping, or `{}` when the pubspec has none (or has a
        `flutter:` that is not a mapping).
    """
    flutter = fields.get("flutter")
    return flutter if type(flutter) == "dict" else {}

# ---------------------------------------------------------------------------
# flutter.plugin
# ---------------------------------------------------------------------------

def _coerce_plugin_value(v):
    # Booleans stay booleans; everything else stringifies. None → empty string.
    if type(v) == "bool":
        return v
    if v == None:
        return ""
    return str(v)

def flutter_plugin_block(fields):
    """Project `flutter.plugin` out of a pubspec's fields.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        A struct with:
            present: bool — True iff a `flutter.plugin` block exists.
            platforms: dict of `<platform> -> dict[key, value]`. Empty dict
                when no `platforms:` key is present.
            implements: str — value of `flutter.plugin.implements` or `""`.
            ffi_plugin: bool — value of `flutter.plugin.ffiPlugin` or False.
    """
    flutter = flutter_block(fields)
    plugin = flutter.get("plugin")
    if type(plugin) != "dict":
        return struct(
            present = False,
            platforms = {},
            implements = "",
            ffi_plugin = False,
        )

    platforms_raw = plugin.get("platforms", {})
    platforms = {}
    if type(platforms_raw) == "dict":
        for name, info in platforms_raw.items():
            if type(info) == "dict":
                platforms[name] = {k: _coerce_plugin_value(v) for k, v in info.items()}

    implements_raw = plugin.get("implements", "")
    implements = str(implements_raw) if implements_raw != None else ""

    ffi_raw = plugin.get("ffiPlugin", False)
    ffi_plugin = ffi_raw if type(ffi_raw) == "bool" else False

    return struct(
        present = True,
        platforms = platforms,
        implements = implements,
        ffi_plugin = ffi_plugin,
    )

# ---------------------------------------------------------------------------
# flutter.fonts / flutter.assets / flutter.shaders / flutter.uses-material-design
# ---------------------------------------------------------------------------

def _project_fonts(raw):
    if type(raw) != "list":
        return []
    out = []
    for entry in raw:
        if type(entry) != "dict":
            continue
        family = entry.get("family")
        if type(family) != "string":
            continue
        fonts_raw = entry.get("fonts", [])
        if type(fonts_raw) != "list":
            fonts_raw = []
        fonts = []
        for f in fonts_raw:
            if type(f) != "dict":
                continue
            asset = f.get("asset")
            if type(asset) != "string":
                continue
            weight = f.get("weight")
            style = f.get("style")
            fonts.append(struct(
                asset = asset,
                weight = weight if type(weight) == "int" else None,
                style = style if type(style) == "string" else None,
            ))
        out.append(struct(family = family, fonts = fonts))
    return out

def _project_assets(raw):
    if type(raw) != "list":
        return []
    out = []
    for entry in raw:
        if type(entry) == "string":
            out.append(struct(path = entry, flavors = [], platforms = [], transformers = []))
            continue
        if type(entry) != "dict":
            continue
        path = entry.get("path")
        if type(path) != "string":
            continue
        flavors_raw = entry.get("flavors", [])
        platforms_raw = entry.get("platforms", [])
        transformers_raw = entry.get("transformers", [])
        out.append(struct(
            path = path,
            flavors = [str(f) for f in flavors_raw] if type(flavors_raw) == "list" else [],
            platforms = [str(p) for p in platforms_raw] if type(platforms_raw) == "list" else [],
            transformers = transformers_raw if type(transformers_raw) == "list" else ([transformers_raw] if transformers_raw else []),
        ))
    return out

def _project_shaders(raw):
    if type(raw) != "list":
        return []
    out = []
    for entry in raw:
        if type(entry) == "string":
            out.append(struct(path = entry, flavors = [], platforms = []))
            continue
        if type(entry) == "dict":
            path = entry.get("path")
            if type(path) == "string":
                flavors_raw = entry.get("flavors", [])
                platforms_raw = entry.get("platforms", [])
                out.append(struct(
                    path = path,
                    flavors = [str(f) for f in flavors_raw] if type(flavors_raw) == "list" else [],
                    platforms = [str(p) for p in platforms_raw] if type(platforms_raw) == "list" else [],
                ))
    return out

def flutter_assets_block(fields):
    """Project `flutter.fonts`, `flutter.assets`, `flutter.shaders`, and `flutter.uses-material-design`.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        struct(
            fonts:    list[struct(family, fonts=list[struct(asset, weight, style)])],
            assets:   list[struct(path, flavors, platforms, transformers)],
            shaders:  list[struct(path, flavors, platforms)],
            uses_material_design: bool,
        )

    `weight` and `style` on a font are None when unset. `flavors`/`platforms`
    are captured from modern-shape asset and shader entries; `flutter_pub_package`
    acts on them.
    """
    flutter = flutter_block(fields)
    umd_raw = flutter.get("uses-material-design", False)
    return struct(
        fonts = _project_fonts(flutter.get("fonts")),
        assets = _project_assets(flutter.get("assets")),
        shaders = _project_shaders(flutter.get("shaders")),
        uses_material_design = umd_raw if type(umd_raw) == "bool" else False,
    )

def flutter_licenses_block(fields):
    """Project `flutter.licenses`, the licence files a package adds to `NOTICES`.

    Args:
        fields: A pubspec's `fields`, as `read_pubspec` returns them.

    Returns:
        The paths, relative to the package, in the order listed. Each item is
        taken as a string, as flutter_tools does (`flutter_manifest.dart`);
        a `licenses:` that is not a list names none.
    """
    raw = flutter_block(fields).get("licenses")
    if type(raw) != "list":
        return []
    return [str(item) for item in raw]
