/// The screens a device draws to, and which one a screenshot takes.
///
/// Most devices have one, and a screenshot of it needs no choice. A few have
/// several: an iPhone Duo simulator has two built-in displays and an app draws
/// on whichever the posture (folded, half open, open) turns on; an iPhone
/// mirrored to a wireless display has a second, external one. The rules here
/// pick the screen the app is on, and refuse to guess when they cannot tell.
library;

import 'dart:async';

import 'package:clock/clock.dart';

/// One screen of a device.
class Screen {
  /// What a caller passes to select this screen: devicectl's `uniqueId` where
  /// the display has one, `displayId:<n>` where it does not, `main` on a
  /// device with a single screen that has no id of its own.
  ///
  /// A unique id changes on every boot of a simulator, so a screen is looked up
  /// anew for each request and never remembered.
  final String id;

  final String name;

  /// What the platform calls this kind of screen. Apple's own `type` field for
  /// an iOS display (`integrated`, `wireless`, `tvOut`, `carPlay`, …); null on
  /// a device that has one screen and does not say.
  final String? type;

  /// Apple's `displayId`, which is stable where a `uniqueId` is not and is the
  /// only handle a display with no `uniqueId` has.
  final int? displayId;

  final int? width;
  final int? height;

  /// Whether the app is drawing here now: true, false, or null when the device
  /// does not say (every one-screen device, and a simulator before it has
  /// reported its posture).
  final bool? active;

  /// Whether the platform captures this screen when none is named.
  final bool primary;

  /// The value of devicectl's `--display-unique-id` that captures this screen,
  /// or null when it has no unique id and can only be captured as the primary.
  final String? captureId;

  const Screen({
    required this.id,
    required this.name,
    this.type,
    this.displayId,
    this.width,
    this.height,
    this.active,
    this.primary = false,
    this.captureId,
  });

  /// The one screen of a device that has one and has nothing more to say about
  /// it. Its [name] is the device's.
  const Screen.only(this.name)
    : id = 'main',
      type = null,
      displayId = null,
      width = null,
      height = null,
      active = null,
      primary = true,
      captureId = null;

  /// Whether the app is on this screen unless a caller says otherwise. A
  /// device's built-in displays are; an external one (wireless, TV, CarPlay) is
  /// a real screen that a caller can ask for by name and is never the default.
  bool get isBuiltIn => type == null || type == 'integrated';

  /// Whether this screen can be captured at all: it has a unique id to name,
  /// or it is the primary one, which devicectl captures when no id is given.
  bool get capturable => captureId != null || primary;

  /// Whether [request] names this screen: by [id], by `displayId:<n>`, or by
  /// [name].
  bool matches(String request) =>
      request == id ||
      request == name ||
      (displayId != null && request == 'displayId:$displayId');

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'width': width,
    'height': height,
    'active': active,
    'primary': primary,
  };

  /// One line for an error message.
  String describe() {
    final size = width != null && height != null ? '${width}x$height' : null;
    final state = switch (active) {
      true => 'active',
      false => 'not active',
      null => 'active unknown',
    };
    return '$name (id $id'
        '${type == null ? '' : ', $type'}'
        '${size == null ? '' : ', $size'}, $state'
        '${capturable ? '' : ', cannot be captured: no unique id and not primary'}'
        ')';
  }

  @override
  String toString() => describe();
}

/// A request for a screenshot that names no screen, or an unknown one, and
/// that the device's screens cannot settle.
class ScreenSelectionException implements Exception {
  final String reason;
  final List<Screen> screens;

  ScreenSelectionException(this.reason, this.screens);

  /// The reason, then every screen and the way to name one.
  String get message => [
    reason,
    'Screens:',
    for (final screen in screens) '  ${screen.describe()}',
    'Name one with `screen=<id or name>`.',
  ].join('\n');

  @override
  String toString() => message;
}

/// What [chooseScreen] decided.
sealed class ScreenChoice {
  const ScreenChoice();
}

/// Take this screen.
final class ChosenScreen extends ScreenChoice {
  final Screen screen;
  const ChosenScreen(this.screen);
}

/// A device with several built-in screens has not yet said which one is
/// active. A simulator reports nothing for a while after it boots, so this is
/// a state to wait out, not an ambiguity.
final class PostureNotReported extends ScreenChoice {
  const PostureNotReported();
}

/// Choose the screen a screenshot of [screens] takes.
///
/// With [requested], the one screen it names. Without, the device's one
/// built-in screen, or of several the one reporting `active: true`. Never a
/// guess: several actives, none, or a request that names no screen or two
/// throw [ScreenSelectionException], listing the screens. Only a device whose
/// built-in screens have all yet to report `active` answers
/// [PostureNotReported].
ScreenChoice chooseScreen(List<Screen> screens, String? requested) {
  if (screens.isEmpty) {
    throw ScreenSelectionException('The device reported no screens.', screens);
  }

  if (requested != null) {
    final named = screens.where((s) => s.matches(requested)).toList();
    if (named.isEmpty) {
      throw ScreenSelectionException(
        'No screen is named "$requested".',
        screens,
      );
    }
    if (named.length > 1) {
      throw ScreenSelectionException(
        '"$requested" names ${named.length} screens.',
        screens,
      );
    }
    return ChosenScreen(_capturable(named.single, screens));
  }

  final builtIn = screens.where((s) => s.isBuiltIn).toList();
  if (builtIn.isEmpty) {
    throw ScreenSelectionException(
      'The device has no built-in screen, and an external one is never '
      'chosen by default.',
      screens,
    );
  }
  if (builtIn.length == 1) {
    return ChosenScreen(_capturable(builtIn.single, screens));
  }
  if (builtIn.every((s) => s.active == null)) {
    return const PostureNotReported();
  }
  final active = builtIn.where((s) => s.active == true).toList();
  if (active.length != 1) {
    throw ScreenSelectionException(
      active.isEmpty
          ? 'The device has ${builtIn.length} built-in screens and none is '
                'active.'
          : '${active.length} of the device\'s built-in screens are active.',
      screens,
    );
  }
  return ChosenScreen(_capturable(active.single, screens));
}

Screen _capturable(Screen screen, List<Screen> screens) {
  if (screen.capturable) return screen;
  throw ScreenSelectionException(
    '${screen.name} cannot be captured: it has no unique id, and only the '
    'primary screen can be captured without one.',
    screens,
  );
}

/// One deadline for the whole of a screenshot, handed from step to step.
///
/// A screenshot lists the device's screens, may ask again while a device has
/// not said which is active, and then captures. Each step bounded on its own
/// would let a request take several times the number written down, and what
/// has to be bounded is what the caller waits for. So the deadline is taken
/// once, at the start, and every step gets what is left.
class ScreenshotDeadline {
  /// Time is read from the ambient `package:clock` [clock], and the waits that
  /// spend it are the zone's timers, so a test that runs a screenshot under
  /// `fakeAsync` drives the deadline with `elapse` and nothing else.
  ScreenshotDeadline(this.total) : _elapsed = clock.stopwatch()..start();

  final Duration total;
  final Stopwatch _elapsed;

  Duration get remaining {
    final left = total - _elapsed.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  bool get expired => remaining == Duration.zero;

  /// What to give a program's own `--timeout`, in whole seconds, never less
  /// than one: a program told zero may read it as no limit.
  int get seconds => (remaining.inMilliseconds / 1000).ceil().clamp(1, 1 << 30);

  /// Runs [work], a step that [step] describes in words an error can use
  /// ("listing the device's screens"), against what is left of the deadline.
  ///
  /// A step that is still running at the deadline, or that failed once the
  /// deadline had passed (a program given [seconds] kills itself and fails),
  /// is a [ScreenshotTimeout] naming the step, not whatever the step said.
  Future<T> within<T>(String step, Future<T> Function() work) async {
    if (expired) throw ScreenshotTimeout(step, total);
    try {
      return await work().timeout(
        remaining,
        onTimeout: () => throw ScreenshotTimeout(step, total),
      );
    } on ScreenshotTimeout {
      rethrow;
    } catch (e) {
      if (expired) throw ScreenshotTimeout(step, total, cause: e);
      rethrow;
    }
  }
}

/// A screenshot ran out of its deadline, in [step].
class ScreenshotTimeout extends StateError {
  ScreenshotTimeout(this.step, Duration total, {Object? cause})
    : super(
        'The screenshot\'s ${_describe(total)} ran out while $step'
        '${cause == null ? '' : ': $cause'}.',
      );

  final String step;
}

String _describe(Duration d) =>
    d.inMilliseconds % 1000 == 0 ? '${d.inSeconds}s' : '${d.inMilliseconds}ms';

/// Resolve [requested] against what [list] reports, asking again while a
/// device with several built-in screens has not yet said which is active.
///
/// Waits on that state, [interval] apart, within [deadline]; a device that
/// still has not said by then is reported as such.
Future<Screen> resolveScreenOf(
  Future<List<Screen>> Function(ScreenshotDeadline) list,
  String? requested, {
  required ScreenshotDeadline deadline,
  required Duration interval,
}) async {
  // The screens the last ask found with no posture reported, once there is
  // one: from then on what the screenshot is waiting for is the posture, even
  // when the deadline lands inside the next ask.
  List<Screen>? unreported;
  ScreenSelectionException ranOut(List<Screen> screens) =>
      ScreenSelectionException(
        'The screenshot\'s ${_describe(deadline.total)} ran out while '
        'waiting for the device to report which of its screens is active.',
        screens,
      );
  while (true) {
    final List<Screen> screens;
    try {
      screens = await list(deadline);
    } on ScreenshotTimeout {
      if (unreported != null) throw ranOut(unreported);
      rethrow;
    }
    switch (chooseScreen(screens, requested)) {
      case ChosenScreen(:final screen):
        return screen;
      case PostureNotReported():
        unreported = screens;
        if (deadline.remaining <= interval) throw ranOut(screens);
        await Future<void>.delayed(interval);
    }
  }
}
