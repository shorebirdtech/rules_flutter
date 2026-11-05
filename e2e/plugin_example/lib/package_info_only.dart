import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// An app that uses one plugin, `package_info_plus`, of the many pubspec.lock
/// lists. Its Android APK is what `verify_android_plugin_scope_test` checks
/// for the code of the plugins it does not use.
void main() {
  runApp(const _PackageName());
}

class _PackageName extends StatelessWidget {
  const _PackageName();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) => Directionality(
        textDirection: TextDirection.ltr,
        child: Text(snapshot.data?.appName ?? ''),
      ),
    );
  }
}
