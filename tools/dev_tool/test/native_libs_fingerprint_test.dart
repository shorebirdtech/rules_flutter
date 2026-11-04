import 'dart:io';

import 'package:flutter_bazel_dev_tool/native_libs_fingerprint.dart';
import 'package:test/test.dart';

import 'zip_fixture.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nlf_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Directory makeBundle(String name, {required List<int> dylibBytes}) {
    final app = Directory('${tmp.path}/$name.app');
    final frameworks = Directory('${app.path}/Contents/Frameworks')
      ..createSync(recursive: true);
    File('${frameworks.path}/libdemo.dylib').writeAsBytesSync(dylibBytes);
    // Framework contents must be excluded: App.framework carries the kernel
    // and changes on every Dart edit.
    final fw = Directory('${frameworks.path}/App.framework/Versions/A')
      ..createSync(recursive: true);
    File('${fw.path}/App').writeAsBytesSync([1, 2, 3]);
    File('${app.path}/Contents/MacOS/runner')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9, 9]);
    return app;
  }

  Future<String> zipBundle(Directory app) async {
    final zipPath = '${app.path}.zip';
    zipTree(
      zipPath: zipPath,
      base: app.parent.path,
      include: [app.uri.pathSegments.lastWhere((s) => s.isNotEmpty)],
      deflate: true,
    );
    return zipPath;
  }

  test('extracted bundle: loose dylibs only, content-sensitive', () async {
    final app = makeBundle('a', dylibBytes: [1, 2, 3, 4]);
    final fp = await nativeLibsFingerprint(app.path);
    expect(fp.keys, ['Contents/Frameworks/libdemo.dylib']);

    final same = await nativeLibsFingerprint(app.path);
    expect(fingerprintsEqual(fp, same), isTrue);

    File(
      '${app.path}/Contents/Frameworks/libdemo.dylib',
    ).writeAsBytesSync([1, 2, 3, 5]);
    final changedFp = await nativeLibsFingerprint(app.path);
    expect(fingerprintsEqual(fp, changedFp), isFalse);
    expect(changedLibs(fp, changedFp), ['Contents/Frameworks/libdemo.dylib']);
  });

  test('framework edits do not change the fingerprint', () async {
    final app = makeBundle('b', dylibBytes: [1, 2, 3, 4]);
    final fp = await nativeLibsFingerprint(app.path);
    File(
      '${app.path}/Contents/Frameworks/App.framework/Versions/A/App',
    ).writeAsBytesSync([4, 5, 6, 7, 8]);
    final after = await nativeLibsFingerprint(app.path);
    expect(fingerprintsEqual(fp, after), isTrue);
  });

  test(
    'zip artifact: TOC fingerprint, content-sensitive, frameworks excluded',
    () async {
      final app = makeBundle('c', dylibBytes: List.filled(1000, 7));
      final zip1 = await zipBundle(app);
      final fp1 = await nativeLibsFingerprint(zip1);
      expect(fp1.keys.single, endsWith('Contents/Frameworks/libdemo.dylib'));

      // Dart-edit analog: framework payload changes, dylib unchanged.
      File(
        '${app.path}/Contents/Frameworks/App.framework/Versions/A/App',
      ).writeAsBytesSync(List.filled(500, 3));
      File(zip1).deleteSync();
      final zip2 = await zipBundle(app);
      final fp2 = await nativeLibsFingerprint(zip2);
      expect(
        fingerprintsEqual(fp1, fp2),
        isTrue,
        reason: 'framework change must not trigger relaunch',
      );

      // Rust-edit analog: dylib bytes change.
      File(
        '${app.path}/Contents/Frameworks/libdemo.dylib',
      ).writeAsBytesSync(List.filled(1000, 8));
      File(zip2).deleteSync();
      final zip3 = await zipBundle(app);
      final fp3 = await nativeLibsFingerprint(zip3);
      expect(fingerprintsEqual(fp1, fp3), isFalse);
    },
  );

  group('native code inside frameworks', () {
    // iOS forbids loose dylibs, so every `native_deps` library ships as
    // `<name>.framework/<name>`. Excluding frameworks wholesale left an iOS
    // app with an empty fingerprint: a native edit restarted into the old
    // machine code and reported success.
    Directory makeIosBundle(String name, {required List<int> addBytes}) {
      final app = Directory('${tmp.path}/$name/Payload/app.app');
      final frameworks = Directory('${app.path}/Frameworks');
      File('${frameworks.path}/add.framework/add')
        ..createSync(recursive: true)
        ..writeAsBytesSync(addBytes);
      File(
        '${frameworks.path}/add.framework/Info.plist',
      ).writeAsStringSync('<plist/>');
      File('${frameworks.path}/App.framework/App')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      File(
          '${frameworks.path}/App.framework/flutter_assets/kernel_blob.bin',
        )
        ..createSync(recursive: true)
        ..writeAsBytesSync([4, 5, 6]);
      File('${frameworks.path}/Flutter.framework/Flutter')
        ..createSync(recursive: true)
        ..writeAsBytesSync([7, 8]);
      return Directory('${tmp.path}/$name');
    }

    Future<String> zipIpa(Directory root) async {
      final ipa = '${root.path}.ipa';
      zipTree(
        zipPath: ipa,
        base: root.path,
        include: ['Payload'],
        deflate: true,
      );
      return ipa;
    }

    test('an iOS native-asset framework binary is a native library', () async {
      final root = makeIosBundle('ios_a', addBytes: [1, 1, 1, 1]);
      final fp = await nativeLibsFingerprint(await zipIpa(root));
      expect(fp.keys, ['Payload/app.app/Frameworks/add.framework/add']);

      File(
        '${root.path}/Payload/app.app/Frameworks/add.framework/add',
      ).writeAsBytesSync([1, 1, 1, 2]);
      File('${root.path}.ipa').deleteSync();
      final after = await nativeLibsFingerprint(await zipIpa(root));
      expect(changedLibs(fp, after), [
        'Payload/app.app/Frameworks/add.framework/add',
      ]);
    });

    test('a Dart edit or engine change still does not count', () async {
      final root = makeIosBundle('ios_b', addBytes: [1, 1, 1, 1]);
      final app = '${root.path}/Payload/app.app';
      final fp = await nativeLibsFingerprint(app);
      expect(fp.keys, ['Frameworks/add.framework/add']);

      File('$app/Frameworks/App.framework/App').writeAsBytesSync([9, 9, 9]);
      File(
        '$app/Frameworks/App.framework/flutter_assets/kernel_blob.bin',
      ).writeAsBytesSync([9]);
      File('$app/Frameworks/Flutter.framework/Flutter').writeAsBytesSync([9]);
      File(
        '$app/Frameworks/add.framework/Info.plist',
      ).writeAsStringSync('<plist>changed</plist>');
      expect(
        fingerprintsEqual(fp, await nativeLibsFingerprint(app)),
        isTrue,
        reason: 'only a native binary changing may buy a relaunch',
      );
    });

    test('an Android APK is read as the zip it is', () async {
      // An .apk carries no .zip suffix, and neither does an .ipa. Reading
      // either as a directory that does not exist fingerprinted every Android
      // and iOS app as having no native libraries at all.
      final root = Directory('${tmp.path}/apk')..createSync();
      final abi = Directory('${root.path}/lib/arm64-v8a')
        ..createSync(recursive: true);
      File('${abi.path}/libadd.so').writeAsBytesSync([1, 2]);
      // Flutter's own: the AOT Dart snapshot and the engine.
      File('${abi.path}/libapp.so').writeAsBytesSync([3, 4]);
      File('${abi.path}/libflutter.so').writeAsBytesSync([5, 6]);
      final apk = '${tmp.path}/app.apk';
      zipTree(zipPath: apk, base: root.path, include: ['lib']);
      expect((await nativeLibsFingerprint(apk)).keys, [
        'lib/arm64-v8a/libadd.so',
      ]);
    });

    test('a versioned macOS plugin framework binary counts', () async {
      final app = makeBundle('mac_plugin', dylibBytes: [1]);
      final frameworks = '${app.path}/Contents/Frameworks';
      File('$frameworks/my_plugin.framework/Versions/A/my_plugin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([3, 3]);
      File('$frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS')
        ..createSync(recursive: true)
        ..writeAsBytesSync([4, 4]);
      final fp = await nativeLibsFingerprint(app.path);
      expect(
        fp.keys,
        unorderedEquals([
          'Contents/Frameworks/libdemo.dylib',
          'Contents/Frameworks/my_plugin.framework/Versions/A/my_plugin',
        ]),
      );
    });
  });

  test('bundle without loose native libs fingerprints empty', () async {
    final app = Directory('${tmp.path}/plain.app');
    Directory(
      '${app.path}/Contents/Frameworks/App.framework',
    ).createSync(recursive: true);
    File(
      '${app.path}/Contents/Frameworks/App.framework/App',
    ).writeAsBytesSync([1]);
    expect(await nativeLibsFingerprint(app.path), isEmpty);
  });

  group('declared build outputs', () {
    test(
      'fingerprints the files a build declared, content-sensitive',
      () async {
        final a = File('${tmp.path}/libone.dylib')..writeAsBytesSync([1, 2, 3]);
        final b = File('${tmp.path}/libtwo.dylib')..writeAsBytesSync([4, 5]);

        final fp = await nativeLibsFingerprintOfFiles([a.path, b.path]);
        expect(fp.keys, unorderedEquals([a.path, b.path]));
        expect(
          fingerprintsEqual(
            fp,
            await nativeLibsFingerprintOfFiles([a.path, b.path]),
          ),
          isTrue,
          reason: 'a rebuild that changed nothing must compare equal',
        );

        // Same length, different bytes: a body-only native edit is exactly this
        // shape, and size alone would miss it.
        b.writeAsBytesSync([4, 6]);
        final after = await nativeLibsFingerprintOfFiles([a.path, b.path]);
        expect(fingerprintsEqual(fp, after), isFalse);
        expect(changedLibs(fp, after), [b.path]);
      },
    );

    test('takes the paths as given, with no filtering by extension', () async {
      // The build declares these, so they are native libraries by construction
      // — a `.so` cross-built on a mac, or a name a suffix test would reject,
      // is still the file the process loaded. Filtering here would silently
      // drop it and report the app as current.
      final odd = File('${tmp.path}/libplugin.jnilib')..writeAsBytesSync([7]);
      expect(await nativeLibsFingerprintOfFiles([odd.path]), hasLength(1));
      expect(await nativeLibsFingerprintOfFiles(const []), isEmpty);
    });

    test(
      'a declared file the build never wrote is an error, not empty',
      () async {
        // Silence here would read as "nothing moved" and let an increment land on
        // stale machine code. The build declared this path; its absence is a
        // broken build, not a state to carry on from.
        await expectLater(
          nativeLibsFingerprintOfFiles(['${tmp.path}/missing.dylib']),
          throwsA(isA<FileSystemException>()),
        );
      },
    );
  });

  group('nativeLibsFingerprintOfBuiltFiles', () {
    // What an Android restart reads in place of the APK: the files the build
    // gives the packaging to take its native libraries from. They sit in an
    // output tree, one directory per configuration.
    File built(String config, String relative, List<int> bytes) =>
        File('${tmp.path}/bazel-out/$config/bin/$relative')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes);

    test('keys each file by where it sits in its configuration', () async {
      final fp = await nativeLibsFingerprintOfBuiltFiles([
        built('k8', 'libdartjni.so', [1, 2, 3]).path,
        built('k8', 'external/lib+/libmul.so', [4]).path,
      ]);
      expect(fp.keys, ['libdartjni.so', 'external/lib+/libmul.so']);
    });

    // `android_binary` links every `cc_library` it lists into a library of its
    // own and packages every AAR's `jni/` libraries, so what can change the
    // APK's native code is archives, objects and extracted libraries too.
    test(
      'takes the archives, objects and libraries the packaging links',
      () async {
        final fp = await nativeLibsFingerprintOfBuiltFiles([
          built('k8', 'libextra_native.lo', [1]).path,
          built('k8', 'libplain.a', [2]).path,
          built('k8', '_objs/plain/plain.pic.o', [3]).path,
          built('k8', 'external/aar+/jni/arm64-v8a/libaar.so', [4]).path,
        ]);
        expect(fp.keys, [
          'libextra_native.lo',
          'libplain.a',
          '_objs/plain/plain.pic.o',
          'external/aar+/jni/arm64-v8a/libaar.so',
        ]);
      },
    );

    test('leaves out the engine and the Dart snapshot', () async {
      final fp = await nativeLibsFingerprintOfBuiltFiles([
        built('k8', 'libdartjni.so', [1]).path,
        built('k8', 'libapp.so', [2]).path,
        built('k8', 'external/engine/libflutter.so', [3]).path,
      ]);
      expect(fp.keys, ['libdartjni.so']);
    });

    test(
      'skips what is not a file: a tree artifact the build listed',
      () async {
        Directory('${tmp.path}/bazel-out/k8/bin/flutter_assets').createSync(
          recursive: true,
        );
        final fp = await nativeLibsFingerprintOfBuiltFiles([
          '${tmp.path}/bazel-out/k8/bin/flutter_assets',
          built('k8', 'libdartjni.so', [1]).path,
        ]);
        expect(fp.keys, ['libdartjni.so']);
      },
    );

    // A launch target reaches one library in more than one configuration (the
    // APK's own and the one its dependencies are split into), and which copy
    // the build lists first is not something to depend on.
    test('does not depend on the order of a library built twice', () async {
      final a = built('config_a', 'libdartjni.so', [1, 2, 3]);
      final b = built('config_b', 'libdartjni.so', [1, 2, 4]);
      final one = await nativeLibsFingerprintOfBuiltFiles([a.path, b.path]);
      final other = await nativeLibsFingerprintOfBuiltFiles([b.path, a.path]);
      expect(one, other);

      b.writeAsBytesSync([1, 2, 5]);
      expect(
        await nativeLibsFingerprintOfBuiltFiles([a.path, b.path]),
        isNot(one),
        reason: 'either copy changing is a change',
      );
    });

    test('moves with a file\'s bytes and not with its configuration', () async {
      final before = await nativeLibsFingerprintOfBuiltFiles([
        built('one', 'libextra.a', [1, 2, 3]).path,
      ]);
      final elsewhere = built('two', 'libextra.a', [1, 2, 3]);
      expect(await nativeLibsFingerprintOfBuiltFiles([elsewhere.path]), before);

      elsewhere.writeAsBytesSync([1, 2, 4]);
      final after = await nativeLibsFingerprintOfBuiltFiles([elsewhere.path]);
      expect(changedLibs(before, after), ['libextra.a']);
    });
  });
}
