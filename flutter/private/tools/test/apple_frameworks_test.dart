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
    write('fw/App.framework/Versions/A/App', 'binary');
    write('fw/App.framework/Versions/A/Resources/Info.plist', 'plist');
    write('fw/App.framework/Versions/A/_CodeSignature/CodeResources', 'seal');
    linkVersions(Directory('${dir.path}/fw/App.framework'));
    expect(linkTarget('fw/App.framework/Versions/Current'), 'A');
    expect(linkTarget('fw/App.framework/App'), 'Versions/Current/App');
    expect(
      linkTarget('fw/App.framework/Resources'),
      'Versions/Current/Resources',
    );
    expect(linkTarget('fw/App.framework/_CodeSignature'), isNull);
    expect(read('fw/App.framework/Resources/Info.plist'), 'plist');
  });

  // How an action sees a versioned framework that had its links: copies at
  // their places.
  void writeFollowed() {
    for (final prefix in [
      'in/X.xcframework/macos-arm64/X.framework/Versions/A',
      'in/X.xcframework/macos-arm64/X.framework/Versions/Current',
      'in/X.xcframework/macos-arm64/X.framework',
    ]) {
      write('$prefix/X', 'binary');
      write('$prefix/Headers/X.h', 'header');
    }
    write('in/X.xcframework/Info.plist', 'xcframework plist');
    write('in/X.xcframework/_CodeSignature/CodeResources', 'outer');
  }

  List<String> namesIn(String path) => [
    for (final e in Directory('${dir.path}/$path').listSync())
      e.path.split('/').last,
  ];

  test('copies a versioned framework as its version directory', () {
    writeFollowed();
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
    expect(namesIn(fw), ['Versions']);
    expect(namesIn('$fw/Versions'), ['A']);
  });

  test('copies a versioned framework with its links made again', () {
    writeFollowed();
    copyBundle(
      Directory('${dir.path}/in/X.xcframework'),
      Directory('${dir.path}/out/X.xcframework'),
      link: true,
    );
    const fw = 'out/X.xcframework/macos-arm64/X.framework';
    expect(linkTarget('$fw/Versions/Current'), 'A');
    expect(linkTarget('$fw/X'), 'Versions/Current/X');
    expect(linkTarget('$fw/Headers'), 'Versions/Current/Headers');
    expect(namesIn(fw), unorderedEquals(['Versions', 'X', 'Headers']));
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
      () => copyBundle(
        Directory('${dir.path}/in/X.framework'),
        Directory('${dir.path}/out/X.framework'),
        link: true,
      ),
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
