/// What [NativeLibsWatch] answers, which is the only thing standing between a
/// rebuilt native library and an increment injected over machine code that cannot
/// serve it.
import 'dart:io';

import 'package:flutter_bazel_dev_tool/native_libs_watch.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nlw_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File file(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('current while the build writes the same bytes', () async {
    final lib = file('liba.dylib', [1, 2, 3]);
    final watch = await NativeLibsWatch.of({lib.path: const []});

    expect(await watch.verdict(), isA<NativeLibsCurrent>());
    // A rebuild that re-ran the native action and produced identical bytes —
    // measured in this repo: editing `a * b` to `a * b + 0` advances the output's
    // mtime, and a `-c dbg` compile can still emit the same image. Reporting it
    // would withhold a reload that was perfectly safe.
    lib.writeAsBytesSync([1, 2, 3]);
    expect(await watch.verdict(), isA<NativeLibsCurrent>());
  });

  group('a library with no declared contract', () {
    test(
      'withholds, because nothing says whether its bindings moved',
      () async {
        final lib = file('libsqlite3.dylib', [1]);
        final watch = await NativeLibsWatch.of({lib.path: const []});

        lib.writeAsBytesSync([2]);
        expect(
          await watch.verdict(),
          isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
            lib.path,
          ]),
        );
      },
    );

    test('withholds even beside a library whose contract held', () async {
      // Unknown beats known-safe: one library nothing describes is enough to
      // make the whole increment unsafe, however many of its neighbours declared
      // a contract.
      final bridge = file('libbridge.dylib', [1]);
      final contract = file('codegen.ir', [10]);
      final other = file('libother.dylib', [2]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
        other.path: const [],
      });

      bridge.writeAsBytesSync([3]);
      other.writeAsBytesSync([4]);
      expect(
        await watch.verdict(),
        isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
          other.path,
        ]),
      );
    });
  });

  group('a library with a declared contract', () {
    test('delivers when only its code moved', () async {
      final bridge = file('libbridge.dylib', [1, 2, 3]);
      final contract = file('codegen.ir', [10, 11]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      // The body-only edit: the library is rebuilt, the interface it was
      // generated from is byte-identical, so the bindings about to be injected
      // are ones the loaded image can still serve.
      bridge.writeAsBytesSync([1, 2, 4]);
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [bridge.path]),
      );
    });

    test('withholds when the contract moved with it', () async {
      final bridge = file('libbridge.dylib', [1]);
      final contract = file('codegen.ir', [10]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      bridge.writeAsBytesSync([2]);
      contract.writeAsBytesSync([11]);
      final verdict = await watch.verdict();
      expect(
        verdict,
        isA<NativeBindingsMoved>()
            .having((v) => v.libs, 'libs', [bridge.path])
            .having((v) => v.contracts, 'contracts', [contract.path]),
      );
    });

    test('withholds on a contract that moved without its library', () async {
      // Not a shape one build produces — the interface and the library come from
      // the same source — so the answer is the safe one rather than a special
      // case. Naming the library rather than only the contract is what makes the
      // reply about something the reader recognises.
      final bridge = file('libbridge.dylib', [1]);
      final contract = file('codegen.ir', [10]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      contract.writeAsBytesSync([11]);
      expect(
        await watch.verdict(),
        isA<NativeBindingsMoved>().having((v) => v.libs, 'libs', [bridge.path]),
      );
    });
  });

  test('keeps saying so until the process is replaced', () async {
    final lib = file('liba.dylib', [1]);
    final watch = await NativeLibsWatch.of({lib.path: const []});
    lib.writeAsBytesSync([2]);

    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
    // Asked again with nothing changed in between: the app is still running the
    // old image, so the answer is still the same. A watch that advanced its
    // baseline on merely *reporting* a change would let the next reload inject
    // over stale machine code — the build has moved on, the process has not.
    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
  });

  test('a relaunch is what clears it', () async {
    final bridge = file('libbridge.dylib', [1]);
    final contract = file('codegen.ir', [10]);
    final watch = await NativeLibsWatch.of({
      bridge.path: [contract.path],
    });
    bridge.writeAsBytesSync([2]);
    contract.writeAsBytesSync([11]);
    expect(await watch.verdict(), isA<NativeBindingsMoved>());

    // The process was replaced, so it launched with the files on disk now.
    await watch.markLive();
    expect(await watch.verdict(), isA<NativeLibsCurrent>());

    // And the next change is caught against the new baseline, not the old one.
    bridge.writeAsBytesSync([3]);
    expect(await watch.verdict(), isA<NativeCodeStale>());
  });

  group('an app whose reload runs no build', () {
    // The silent shape this closes: nothing rebuilds the library between
    // reloads, so comparing libraries alone answered "current" to a native
    // edit and the increment went in over the machine code the app launched
    // with.
    test('reports the libraries when a native source moved', () async {
      final lib = file('libbridge.dylib', [1]);
      final contract = file('bridge.h', [10]);
      final source = file('bridge.c', [20]);
      final watch = await NativeLibsWatch.of(
        {
          lib.path: [contract.path],
        },
        sources: {
          lib.path: [source.path],
        },
      );

      expect(await watch.verdict(), isA<NativeLibsCurrent>());
      source.writeAsBytesSync([21]);
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [lib.path]),
        reason: 'the library is not rebuilt, so only its source can say this',
      );
      // And keeps saying it: only a new process, or a patch, changes what the
      // app is running.
      expect(await watch.verdict(), isA<NativeCodeStale>());

      await watch.markLive();
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });

    test('a source rewritten with the same bytes is not a change', () async {
      final lib = file('libbridge.dylib', [1]);
      final source = file('bridge.c', [20]);
      final watch = await NativeLibsWatch.of(
        {
          lib.path: const [],
        },
        sources: {
          lib.path: [source.path],
        },
      );

      source.writeAsBytesSync([20]);
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });

    test('answers for the library whose source moved, and no other', () async {
      final patched = file('libbridge.dylib', [1]);
      final other = file('libother.dylib', [2]);
      final bridgeSource = file('bridge.c', [20]);
      final otherSource = file('other.c', [30]);
      final watch = await NativeLibsWatch.of(
        {
          patched.path: const [],
          other.path: const [],
        },
        sources: {
          patched.path: [bridgeSource.path],
          other.path: [otherSource.path],
        },
      );

      bridgeSource.writeAsBytesSync([21]);
      expect(
        await watch.verdict(),
        isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
          patched.path,
        ]),
        reason: 'an edit to one library says nothing about the other',
      );

      // A patch delivered that library's code, so its source goes live with it:
      // the app runs what the source says now.
      await watch.markPatched({'libbridge.dylib'});
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });
  });

  test(
    'a native hot patch clears the library it delivered, and only that',
    () async {
      final bridge = file('libbridge.dylib', [1]);
      final other = file('libother.dylib', [5]);
      final contract = file('codegen.ir', [10]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
        other.path: [contract.path],
      });
      bridge.writeAsBytesSync([2]);
      other.writeAsBytesSync([6]);

      // A patch put libbridge's new code into the running process; libother
      // still runs what it launched with.
      await watch.markPatched({'libbridge.dylib'});
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [other.path]),
      );
    },
  );

  test('a native hot patch clears the contract it was asked about', () async {
    final bridge = file('libbridge.dylib', [1]);
    final contract = file('codegen.ir', [10]);
    final watch = await NativeLibsWatch.of({
      bridge.path: [contract.path],
    });
    // The shape a bridged function being added makes: the library moved and so
    // did what its bindings are generated from. The pipeline asks the patch
    // builder about exactly this, and only calls markPatched once the builder
    // has said it served it.
    bridge.writeAsBytesSync([2]);
    contract.writeAsBytesSync([11]);
    expect(await watch.verdict(), isA<NativeBindingsMoved>());

    await watch.markPatched({'libbridge.dylib'});
    // Not still `NativeBindingsMoved`: the next reload reads the same moved
    // contract bytes, and withholding over an image that caught up an edit ago
    // would take the rest of the run with it.
    expect(await watch.verdict(), isA<NativeLibsCurrent>());
  });

  test('a declared file the build never wrote is loud', () async {
    final lib = file('liba.dylib', [1]);
    final watch = await NativeLibsWatch.of({lib.path: const []});
    lib.deleteSync();
    // Not "current", which would let an increment land on stale machine code,
    // and not "moved", which would blame the app's source for a broken build.
    // The build declared this path and did not write it.
    await expectLater(watch.verdict(), throwsA(isA<FileSystemException>()));
  });

  /// A watched file that changed is reported as changed, whatever its size and
  /// mtime say.
  ///
  /// A file can be rewritten to the same size in the same mtime tick (a
  /// filesystem with a coarse timestamp: FAT and exFAT round to 2 s, some
  /// network and VM shares to 1 s) or by a tool that keeps the old mtime
  /// (`cp -p`, `rsync -t`, `install -p`), which leaves the stamp exactly as it
  /// was. The watch decides from content alone, so how recently the file was
  /// written, or what time it claims, changes nothing. Answering "current" over
  /// changed bytes lets a reload inject over machine code from before the edit.
  group('an edit that leaves size and mtime as they were', () {
    /// Rewrites [target] with [bytes] and puts its stamp back.
    void rewriteKeepingStamp(File target, List<int> bytes) {
      final stamp = target.statSync().modified;
      target.writeAsBytesSync(bytes);
      target.setLastModifiedSync(stamp);
    }

    /// How a file comes to be stamped at the moment its baseline is read.
    final stampedAtBaseline = <String, void Function(File)>{
      // Written, and read straight away: the stamp is a few milliseconds
      // older than the read, inside any filesystem's tick.
      'written just before the baseline is read': (_) {},
      // A stamp that is not before the read at all: clock skew against a
      // network share, or a tool that set it.
      'stamped in the future': (f) =>
          f.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5))),
    };

    for (final MapEntry(key: stamping, value: stampIt)
        in stampedAtBaseline.entries) {
      test('is seen in a library with no contract ($stamping)', () async {
        final lib = file('liba.dylib', [1, 2, 3]);
        stampIt(lib);
        final watch = await NativeLibsWatch.of({lib.path: const []});

        rewriteKeepingStamp(lib, [9, 9, 9]);

        expect(await watch.verdict(), isNot(isA<NativeLibsCurrent>()));
      });

      test('is seen in a library whose contract held ($stamping)', () async {
        final bridge = file('libbridge.dylib', [1, 2, 3]);
        final contract = file('codegen.ir', [10, 11]);
        stampIt(bridge);
        stampIt(contract);
        final watch = await NativeLibsWatch.of({
          bridge.path: [contract.path],
        });

        rewriteKeepingStamp(bridge, [1, 2, 4]);

        expect(
          await watch.verdict(),
          isA<NativeCodeStale>().having((v) => v.libs, 'libs', [bridge.path]),
        );
      });

      test('is seen in the bindings contract ($stamping)', () async {
        final bridge = file('libbridge.dylib', [1, 2, 3]);
        final contract = file('codegen.ir', [10, 11]);
        stampIt(bridge);
        stampIt(contract);
        final watch = await NativeLibsWatch.of({
          bridge.path: [contract.path],
        });

        rewriteKeepingStamp(contract, [10, 12]);

        expect(await watch.verdict(), isA<NativeBindingsMoved>());
      });

      test('is seen in a source nothing rebuilt ($stamping)', () async {
        final lib = file('libbridge.dylib', [1, 2, 3]);
        final contract = file('codegen.ir', [10, 11]);
        final source = file('bridge.c', [100, 101]);
        stampIt(source);
        final watch = await NativeLibsWatch.of(
          {
            lib.path: [contract.path],
          },
          sources: {
            lib.path: [source.path],
          },
        );

        rewriteKeepingStamp(source, [100, 102]);

        expect(
          await watch.verdict(),
          isA<NativeCodeStale>().having((v) => v.libs, 'libs', [lib.path]),
        );
      });
    }
  });
}
