import 'dart:io';

import 'package:test/test.dart';

import '../apple_frameworks.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('apple_frameworks'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String relative, String content) {
    final file = File('${dir.path}/$relative')..createSync(recursive: true);
    file.writeAsStringSync(content);
    return file.path;
  }

  String read(String relative) =>
      File('${dir.path}/$relative').readAsStringSync();

  String? linkTarget(String relative) {
    final link = Link('${dir.path}/$relative');
    return link.existsSync() ? link.targetSync() : null;
  }

  int assemble(List<String> steps) =>
      run(['--output', '${dir.path}/out', ...steps]);

  test('places files and trees', () {
    final binary = write('in/App', 'binary');
    write('assets/a.txt', 'a');
    expect(
      assemble([
        '--add',
        'App.framework/App',
        binary,
        '--add-tree',
        'App.framework/flutter_assets',
        '${dir.path}/assets',
      ]),
      0,
    );
    expect(read('out/App.framework/App'), 'binary');
    expect(read('out/App.framework/flutter_assets/a.txt'), 'a');
  });

  test('links a versioned framework', () {
    final binary = write('in/App', 'binary');
    final plist = write('in/Info.plist', 'plist');
    expect(
      assemble([
        '--add',
        'App.framework/Versions/A/App',
        binary,
        '--add',
        'App.framework/Versions/A/Resources/Info.plist',
        plist,
        '--link-versions',
        'App.framework',
      ]),
      0,
    );
    expect(linkTarget('out/App.framework/Versions/Current'), 'A');
    expect(linkTarget('out/App.framework/App'), 'Versions/Current/App');
    expect(
      linkTarget('out/App.framework/Resources'),
      'Versions/Current/Resources',
    );
    expect(read('out/App.framework/Resources/Info.plist'), 'plist');
  });

  test('copies a versioned framework read with its links followed', () {
    // How a sandboxed action sees a versioned framework: copies at the
    // places of the links.
    for (final prefix in [
      'in/X.xcframework/macos-arm64/X.framework/Versions/A',
      'in/X.xcframework/macos-arm64/X.framework/Versions/Current',
      'in/X.xcframework/macos-arm64/X.framework',
    ]) {
      write('$prefix/X', 'binary');
      write('$prefix/Headers/X.h', 'header');
    }
    write(
      'in/X.xcframework/macos-arm64/X.framework/Versions/A/'
          '_CodeSignature/CodeResources',
      'signature',
    );
    write('in/X.xcframework/Info.plist', 'xcframework plist');
    write('in/X.xcframework/_CodeSignature/CodeResources', 'outer');

    expect(
      assemble([
        '--add-bundle',
        'X.xcframework',
        '${dir.path}/in/X.xcframework',
      ]),
      0,
    );
    const fw = 'out/X.xcframework/macos-arm64/X.framework';
    expect(read('out/X.xcframework/Info.plist'), 'xcframework plist');
    expect(read('out/X.xcframework/_CodeSignature/CodeResources'), 'outer');
    expect(read('$fw/Versions/A/X'), 'binary');
    expect(linkTarget('$fw/Versions/Current'), 'A');
    expect(linkTarget('$fw/X'), 'Versions/Current/X');
    expect(linkTarget('$fw/Headers'), 'Versions/Current/Headers');
    expect(linkTarget('$fw/_CodeSignature'), isNull);
    expect(
      Directory('${dir.path}/$fw')
          .listSync()
          .map((e) => e.path.split('/').last),
      unorderedEquals(['Versions', 'X', 'Headers']),
    );
  });

  test('copies a shallow framework as it is', () {
    write('in/X.framework/X', 'binary');
    write('in/X.framework/Headers/X.h', 'header');
    expect(
      assemble(['--add-bundle', 'X.framework', '${dir.path}/in/X.framework']),
      0,
    );
    expect(read('out/X.framework/X'), 'binary');
    expect(read('out/X.framework/Headers/X.h'), 'header');
  });

  test('refuses a versioned framework with two versions', () {
    write('in/X.framework/Versions/A/X', 'a');
    write('in/X.framework/Versions/B/X', 'b');
    expect(
      () => assemble([
        '--add-bundle',
        'X.framework',
        '${dir.path}/in/X.framework',
      ]),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('reads its arguments from a parameter file', () {
    final binary = write('in/App', 'binary');
    final params = write(
      'params',
      [
        '--output',
        '${dir.path}/out',
        '--add',
        'App.framework/App',
        binary,
      ].join('\n'),
    );
    expect(run(['@$params']), 0);
    expect(read('out/App.framework/App'), 'binary');
  });

  test('replaces text in a copied file', () {
    final header = write(
      'in/M-Swift.h',
      '@import Foundation;\n@import M_objc;\n',
    );
    expect(
      assemble([
        '--add-replacing',
        'M.framework/Headers/M-Swift.h',
        header,
        '@import M_objc;',
        '#import "M-umbrella.h"',
      ]),
      0,
    );
    expect(
      read('out/M.framework/Headers/M-Swift.h'),
      '@import Foundation;\n#import "M-umbrella.h"\n',
    );
  });

  test('makes a mixed framework module interface', () {
    expect(
      frameworkInterface(
        '// swift-interface-format-version: 1.0\n'
            '// swift-module-flags: -module-name M\n'
            'import Foundation\n'
            'import M_objc\n'
            'public func f(_ g: M_objc.Greeter, _ h: M_objcExtra.T)\n',
        'M',
        'M_objc',
      ),
      '// swift-interface-format-version: 1.0\n'
      '// swift-module-flags: -module-name M\n'
      '@_exported import M\n'
      'import Foundation\n'
      'import M\n'
      'public func f(_ g: M.Greeter, _ h: M_objcExtra.T)\n',
    );
  });

  test('rejects an unknown argument', () {
    expect(assemble(['--bogus']), 64);
  });
}
