/// What the host does with the goldens an app asks about: the comparator's
/// answer goes back to the app under the app's own id, a failed comparison says
/// so in the comparator's words, and in update mode the pictures are written
/// instead of compared.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/integration/golden_comparator.dart';
import 'package:flutter_bazel_dev_tool/integration/golden_requests.dart';
import 'package:test/test.dart';

class _FakeChannel implements GoldenRequests {
  final requests = StreamController<GoldenRequest>();
  final answers = <int, GoldenAnswer>{};
  final answered = StreamController<int>.broadcast();

  @override
  Stream<GoldenRequest> get goldenRequests => requests.stream;

  @override
  Future<void> answerGolden(int id, GoldenAnswer answer) async {
    answers[id] = answer;
    answered.add(id);
  }

  void ask(int id, String key, {GoldenOperation? operation}) => requests.add(
    GoldenRequest(
      id: id,
      operation: operation ?? GoldenOperation.compare,
      key: key,
      bytes: Uint8List.fromList([id]),
    ),
  );
}

class _FakeComparator implements GoldenComparator {
  final calls = <String>[];
  var closed = false;
  Future<GoldenAnswer> Function(String key)? onCompare;

  @override
  Future<GoldenAnswer> compare(String key, Uint8List bytes) {
    calls.add('compare $key ${bytes.first}');
    return onCompare?.call(key) ??
        Future.value(const GoldenAnswer.matched(true));
  }

  @override
  Future<GoldenAnswer> update(String key, Uint8List bytes) async {
    calls.add('update $key ${bytes.first}');
    return GoldenAnswer.matched(true, wrote: '/ws/pkg/$key');
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late _FakeChannel channel;
  late _FakeComparator comparator;
  late List<String> logged;
  setUp(() {
    logged = [];
    channel = _FakeChannel();
    comparator = _FakeComparator();
  });

  Future<GoldenHost> hostOf({bool update = false}) async =>
      GoldenHost(channel, comparator, update: update, log: logged.add);

  Future<void> answeredId(int id) =>
      channel.answered.stream.firstWhere((answered) => answered == id);

  test('a golden that matches is answered as matching, under the id the app '
      'asked with', () async {
    await hostOf();

    channel.ask(7, 'goldens/a.png');
    await answeredId(7);

    expect(comparator.calls, ['compare goldens/a.png 7']);
    expect(channel.answers[7]!.matched, isTrue);
    expect(channel.answers[7]!.error, isNull);
  });

  test('a comparison that fails is answered with the comparator\'s own words, '
      'which name the golden', () async {
    comparator.onCompare = (key) async => GoldenAnswer.failed(
      'Golden "$key": Pixel test failed, 1.00%, 4px diff detected!',
    );
    await hostOf();

    channel.ask(1, 'goldens/a.png');
    await answeredId(1);

    expect(channel.answers[1]!.matched, isNull);
    expect(
      channel.answers[1]!.error,
      'Golden "goldens/a.png": Pixel test failed, 1.00%, 4px diff detected!',
    );
  });

  test('a comparator that throws fails the golden, naming it, instead of '
      'leaving the app waiting for an answer', () async {
    comparator.onCompare = (key) async => throw StateError('the service died');
    await hostOf();

    channel.ask(1, 'goldens/a.png');
    await answeredId(1);

    expect(channel.answers[1]!.error, contains('goldens/a.png'));
    expect(channel.answers[1]!.error, contains('the service died'));
  });

  test('requests are served one at a time, in the order they were asked: the '
      'second is not compared until the first is answered', () async {
    final first = Completer<GoldenAnswer>();
    comparator.onCompare = (key) => key == 'goldens/a.png'
        ? first.future
        : Future.value(const GoldenAnswer.matched(true));
    await hostOf();

    channel.ask(1, 'goldens/a.png');
    channel.ask(2, 'goldens/b.png');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(comparator.calls, ['compare goldens/a.png 1']);

    first.complete(const GoldenAnswer.matched(true));
    await answeredId(2);
    expect(comparator.calls, [
      'compare goldens/a.png 1',
      'compare goldens/b.png 2',
    ]);
  });

  group('in update mode', () {
    test('a golden the app asks to compare is written, since an app on a '
        'device cannot be told to update', () async {
      await hostOf(update: true);

      channel.ask(1, 'goldens/a.png');
      await answeredId(1);

      expect(comparator.calls, ['update goldens/a.png 1']);
      expect(channel.answers[1]!.matched, isTrue);
    });

    test('the files written are named, since a golden that is written reports '
        'as a passing test', () async {
      await hostOf(update: true);

      channel.ask(1, 'goldens/a.png');
      await answeredId(1);

      expect(logged, ['wrote golden /ws/pkg/goldens/a.png']);
    });
  });

  test(
    'a golden the app asks to update is written when not comparing too',
    () async {
      await hostOf();

      channel.ask(1, 'goldens/a.png', operation: GoldenOperation.update);
      await answeredId(1);

      expect(comparator.calls, ['update goldens/a.png 1']);
    },
  );

  test(
    'closing answers what was asked first, then closes the comparator',
    () async {
      final slow = Completer<GoldenAnswer>();
      comparator.onCompare = (key) => slow.future;
      final host = await hostOf();

      channel.ask(1, 'goldens/a.png');
      await Future<void>.delayed(Duration.zero);
      unawaited(channel.requests.close());
      final closing = host.close();
      await Future<void>.delayed(Duration.zero);
      expect(comparator.closed, isFalse);

      slow.complete(const GoldenAnswer.matched(true));
      await closing;
      expect(channel.answers[1]!.matched, isTrue);
      expect(comparator.closed, isTrue);
    },
  );
}
