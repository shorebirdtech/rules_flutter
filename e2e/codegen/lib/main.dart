import 'package:codegen_e2e/user.dart';
import 'package:dep_lib/catalog.dart';
import 'package:dep_part/settings.dart';
import 'package:flutter/widgets.dart';

void main() {
  runApp(const CodegenApp(user: User('Ada Lovelace', 36)));
}

/// Root widget of the codegen example, which renders generated output from
/// three places at once so a regenerated `.g.dart` is visible on hot reload.
class CodegenApp extends StatelessWidget {
  /// Creates the codegen example's root widget rendering [user].
  const CodegenApp({required this.user, super.key});

  /// The model whose generated `toJson()` this app displays.
  final User user;

  @override
  Widget build(BuildContext context) {
    // Render generated output from the app package (user.g.dart `part`), a
    // dependency's generated `part` (dep_part settings.g.dart) and a
    // dependency's generated imported library (dep_lib catalog.g.dart), all in
    // build() so a regenerated `.g.dart` in any of them is observable on a hot
    // reload.
    const settings = Settings('dark');
    const catalog = Catalog('demo');
    // Widgets only: Flutter 3.50 deprecates package:flutter/material.dart
    // for package:material_ui, which 3.47 has no copy of, and this example
    // runs on both.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: DefaultTextStyle(
          style: const TextStyle(color: Color(0xFF000000), fontSize: 14),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${user.toJson()}'),
                Text('${settings.toJson()}'),
                Text('fields:${catalog.fieldSummary}'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
