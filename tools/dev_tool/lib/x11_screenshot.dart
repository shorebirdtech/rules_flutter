/// A screenshot of an X display, taken over the X11 protocol.
///
/// The Linux device captures the screen its app is on. Flutter cannot do it
/// (the engine has no screenshot under Impeller), and a program such as
/// `scrot` would be a binary taken from the host's `PATH`. The protocol is
/// small enough to speak directly: connect to the display, authenticate with
/// the user's cookie, ask the root window for its pixels with `GetImage`, and
/// write them as a PNG. The capture is of whatever the display shows, as
/// `scrot`'s is: on a Wayland desktop that is the X windows of XWayland.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Where an X display is reached.
class X11Display {
  X11Display._({
    required this.number,
    required this.screen,
    this.host,
  });

  /// Reads a `DISPLAY` value: `:0`, `:0.1`, `unix:0`, `localhost:10.0`.
  /// Throws a [FormatException] for one that is none of these.
  factory X11Display.parse(String value) {
    final match = RegExp(r'^(.*):(\d+)(?:\.(\d+))?$').firstMatch(value);
    if (match == null) {
      throw FormatException('DISPLAY is not an X display name', value);
    }
    final host = match.group(1)!;
    return X11Display._(
      number: int.parse(match.group(2)!),
      screen: int.parse(match.group(3) ?? '0'),
      host: host.isEmpty || host == 'unix' ? null : host,
    );
  }

  /// The display's number: `0` for `:0`.
  final int number;

  /// The screen of the display.
  final int screen;

  /// The host of a display reached over TCP, or null for one on this machine.
  final String? host;

  /// The path of the local display's socket.
  String get socketPath => '/tmp/.X11-unix/X$number';

  Future<Socket> connect() => host == null
      ? Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        )
      : Socket.connect(host, 6000 + number);
}

/// The authorisation a display is opened with.
class X11Authorization {
  const X11Authorization(this.name, this.data);

  /// No authorisation: what a display that asks for none is opened with.
  static const none = X11Authorization('', <int>[]);

  final String name;
  final List<int> data;

  /// The entry of the `Xauthority` file [bytes] for [display], or [none] when
  /// the file has no entry for it.
  ///
  /// An entry is the family (u16), then the address, display number, name and
  /// data, each a u16 length and bytes, all big-endian. An entry is for this
  /// display when it is a wildcard family, or the local family naming
  /// [hostname], and its number is the display's or empty.
  static X11Authorization find(
    List<int> bytes, {
    required int display,
    required String hostname,
  }) {
    final view = ByteData.sublistView(Uint8List.fromList(bytes));
    var at = 0;
    String? readString() {
      if (at + 2 > view.lengthInBytes) return null;
      final length = view.getUint16(at);
      at += 2;
      if (at + length > view.lengthInBytes) return null;
      final value = bytes.sublist(at, at + length);
      at += length;
      return String.fromCharCodes(value);
    }

    List<int>? readBytes() {
      if (at + 2 > view.lengthInBytes) return null;
      final length = view.getUint16(at);
      at += 2;
      if (at + length > view.lengthInBytes) return null;
      final value = bytes.sublist(at, at + length);
      at += length;
      return value;
    }

    while (at + 2 <= view.lengthInBytes) {
      final family = view.getUint16(at);
      at += 2;
      final address = readString();
      final number = readString();
      final name = readString();
      final data = readBytes();
      if (address == null || number == null || name == null || data == null) {
        break;
      }
      const familyLocal = 256;
      const familyWild = 65535;
      final forThisHost =
          family == familyWild ||
          (family == familyLocal && address == hostname);
      final forThisDisplay = number.isEmpty || number == '$display';
      if (forThisHost && forThisDisplay && name == 'MIT-MAGIC-COOKIE-1') {
        return X11Authorization(name, data);
      }
    }
    return none;
  }
}

/// Takes a PNG of the X display `environment['DISPLAY']` names, at
/// [outputPath]. [connect] opens the display's socket, when a test serves it
/// elsewhere than where the name says.
///
/// Throws a [StateError] saying what failed: no `DISPLAY`, a display that
/// cannot be reached or refuses the cookie, a server that answers with an
/// error, or pixels in a layout other than 32 bits of 8-bit red, green and
/// blue.
Future<void> captureX11Screen(
  String outputPath, {
  required Map<String, String> environment,
  String? hostname,
  Future<Socket> Function(X11Display display)? connect,
}) async {
  final value = environment['DISPLAY'];
  if (value == null || value.isEmpty) {
    throw StateError(
      'DISPLAY is not set, so there is no X display to take a screenshot of.',
    );
  }
  final X11Display display;
  try {
    display = X11Display.parse(value);
  } on FormatException catch (e) {
    throw StateError('DISPLAY is "$value", which is ${e.message}.');
  }
  final authorization = _readAuthorization(
    environment,
    display,
    hostname ?? Platform.localHostname,
  );
  final Socket socket;
  try {
    socket = await (connect ?? (d) => d.connect())(display);
  } on SocketException catch (e) {
    throw StateError('Cannot reach the X display "$value": ${e.message}.');
  }
  final connection = _X11Connection(socket);
  try {
    final image = await connection.captureRoot(display.screen, authorization);
    await File(outputPath).writeAsBytes(
      encodePng(image.width, image.height, image.rgb),
      flush: true,
    );
  } finally {
    await connection.close();
  }
}

X11Authorization _readAuthorization(
  Map<String, String> environment,
  X11Display display,
  String hostname,
) {
  final explicit = environment['XAUTHORITY'];
  final home = environment['HOME'];
  final path = explicit != null && explicit.isNotEmpty
      ? explicit
      : home != null && home.isNotEmpty
      ? '$home/.Xauthority'
      : null;
  if (path == null) return X11Authorization.none;
  final file = File(path);
  if (!file.existsSync()) return X11Authorization.none;
  return X11Authorization.find(
    file.readAsBytesSync(),
    display: display.number,
    hostname: hostname,
  );
}

/// The pixels of a capture, as packed red, green, blue bytes.
class X11Image {
  X11Image(this.width, this.height, this.rgb);
  final int width;
  final int height;
  final Uint8List rgb;
}

/// One connection to an X server, spoken in little-endian byte order.
class _X11Connection {
  _X11Connection(this._socket) {
    _subscription = _socket.listen(
      (chunk) {
        _received.add(chunk);
        _wake();
      },
      onError: (Object error) {
        _failure = error;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _received = BytesBuilder(copy: false);
  Completer<void>? _waiting;
  Object? _failure;
  bool _closed = false;

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<void> close() async {
    await _subscription.cancel();
    _socket.destroy();
  }

  /// The next [count] bytes the server sends.
  Future<Uint8List> _read(int count) async {
    while (_received.length < count) {
      final failure = _failure;
      if (failure != null) {
        throw StateError('The X connection failed: $failure');
      }
      if (_closed) {
        throw StateError(
          'The X server closed the connection after ${_received.length} of '
          'the $count bytes it owed.',
        );
      }
      final waiting = _waiting = Completer<void>();
      await waiting.future;
    }
    final all = _received.takeBytes();
    _received.add(Uint8List.sublistView(all, count));
    return Uint8List.sublistView(all, 0, count);
  }

  Future<X11Image> captureRoot(
    int screenIndex,
    X11Authorization authorization,
  ) async {
    final setup = await _handshake(authorization);
    if (screenIndex >= setup.screens.length) {
      throw StateError(
        'The X display has ${setup.screens.length} screen(s), not screen '
        '$screenIndex.',
      );
    }
    final screen = setup.screens[screenIndex];
    final format = setup.formats[screen.rootDepth];
    if (setup.imageByteOrder != 0 ||
        format == null ||
        format.bitsPerPixel != 32 ||
        screen.redMask != 0xff0000 ||
        screen.greenMask != 0x00ff00 ||
        screen.blueMask != 0x0000ff) {
      throw StateError(
        'The X display\'s pixels are not 32-bit little-endian RGB '
        '(depth ${screen.rootDepth}, '
        '${format?.bitsPerPixel ?? 'no'} bits per pixel, masks '
        '${screen.redMask.toRadixString(16)}/'
        '${screen.greenMask.toRadixString(16)}/'
        '${screen.blueMask.toRadixString(16)}), which is all a screenshot '
        'reads.',
      );
    }
    final width = screen.width;
    final height = screen.height;

    // GetImage (opcode 73): ZPixmap of the root window, every plane.
    final request = ByteData(20)
      ..setUint8(0, 73)
      ..setUint8(1, 2)
      ..setUint16(2, 5, Endian.little)
      ..setUint32(4, screen.root, Endian.little)
      ..setInt16(8, 0, Endian.little)
      ..setInt16(10, 0, Endian.little)
      ..setUint16(12, width, Endian.little)
      ..setUint16(14, height, Endian.little)
      ..setUint32(16, 0xffffffff, Endian.little);
    _socket.add(request.buffer.asUint8List());

    while (true) {
      final header = await _read(32);
      final kind = header[0];
      if (kind == 0) {
        throw StateError(
          'The X server refused to read the screen: ${_errorName(header[1])}.',
        );
      }
      if (kind != 1) continue; // An event, which a screenshot ignores.
      final extra =
          ByteData.sublistView(header).getUint32(4, Endian.little) * 4;
      final data = await _read(extra);
      if (extra < width * height * 4) {
        throw StateError(
          'The X server sent $extra bytes for a $width x $height screen.',
        );
      }
      final rgb = Uint8List(width * height * 3);
      for (var i = 0, o = 0; i < width * height * 4; i += 4, o += 3) {
        rgb[o] = data[i + 2];
        rgb[o + 1] = data[i + 1];
        rgb[o + 2] = data[i];
      }
      return X11Image(width, height, rgb);
    }
  }

  Future<_Setup> _handshake(X11Authorization authorization) async {
    int padded(int n) => (n + 3) & ~3;
    final nameBytes = ascii.encode(authorization.name);
    final request = BytesBuilder()
      ..add([0x6c, 0]) // little-endian, padding
      ..add((ByteData(2)..setUint16(0, 11, Endian.little)).buffer.asUint8List())
      ..add((ByteData(2)..setUint16(0, 0, Endian.little)).buffer.asUint8List())
      ..add(
        (ByteData(
          2,
        )..setUint16(0, nameBytes.length, Endian.little)).buffer.asUint8List(),
      )
      ..add(
        (ByteData(2)..setUint16(0, authorization.data.length, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add([0, 0])
      ..add(nameBytes)
      ..add(List.filled(padded(nameBytes.length) - nameBytes.length, 0))
      ..add(authorization.data)
      ..add(
        List.filled(
          padded(authorization.data.length) - authorization.data.length,
          0,
        ),
      );
    _socket.add(request.takeBytes());

    final head = await _read(8);
    final status = head[0];
    final more = ByteData.sublistView(head).getUint16(6, Endian.little) * 4;
    final body = await _read(more);
    if (status != 1) {
      final reason = ascii.decode(
        body.sublist(0, head[1] > body.length ? body.length : head[1]),
        allowInvalid: true,
      );
      throw StateError(
        status == 0
            ? 'The X server refused the connection: $reason'
            : 'The X server asks for authorisation the screenshot cannot '
                  'give: $reason',
      );
    }

    final view = ByteData.sublistView(body);
    final vendorLength = view.getUint16(16, Endian.little);
    final screenCount = body[20];
    final formatCount = body[21];
    final imageByteOrder = body[22];
    var at = 32 + padded(vendorLength);
    final formats = <int, _Format>{};
    for (var i = 0; i < formatCount; i++) {
      formats[body[at]] = _Format(body[at + 1]);
      at += 8;
    }
    final screens = <_Screen>[];
    for (var i = 0; i < screenCount; i++) {
      final root = view.getUint32(at, Endian.little);
      final width = view.getUint16(at + 20, Endian.little);
      final height = view.getUint16(at + 22, Endian.little);
      final rootVisual = view.getUint32(at + 32, Endian.little);
      final rootDepth = body[at + 38];
      final depthCount = body[at + 39];
      at += 40;
      int? red, green, blue;
      for (var d = 0; d < depthCount; d++) {
        final visualCount = view.getUint16(at + 2, Endian.little);
        at += 8;
        for (var v = 0; v < visualCount; v++) {
          if (view.getUint32(at, Endian.little) == rootVisual) {
            red = view.getUint32(at + 8, Endian.little);
            green = view.getUint32(at + 12, Endian.little);
            blue = view.getUint32(at + 16, Endian.little);
          }
          at += 24;
        }
      }
      screens.add(
        _Screen(
          root: root,
          width: width,
          height: height,
          rootDepth: rootDepth,
          redMask: red ?? 0,
          greenMask: green ?? 0,
          blueMask: blue ?? 0,
        ),
      );
    }
    return _Setup(imageByteOrder, formats, screens);
  }
}

String _errorName(int code) => switch (code) {
  3 => 'BadWindow',
  8 => 'BadMatch (the screen is not readable)',
  9 => 'BadDrawable',
  10 => 'BadAccess',
  11 => 'BadAlloc',
  16 => 'BadLength',
  _ => 'error code $code',
};

class _Format {
  _Format(this.bitsPerPixel);
  final int bitsPerPixel;
}

class _Screen {
  _Screen({
    required this.root,
    required this.width,
    required this.height,
    required this.rootDepth,
    required this.redMask,
    required this.greenMask,
    required this.blueMask,
  });
  final int root;
  final int width;
  final int height;
  final int rootDepth;
  final int redMask;
  final int greenMask;
  final int blueMask;
}

class _Setup {
  _Setup(this.imageByteOrder, this.formats, this.screens);
  final int imageByteOrder;
  final Map<int, _Format> formats;
  final List<_Screen> screens;
}

/// A PNG of [rgb], packed red, green, blue bytes of a [width] x [height]
/// image.
Uint8List encodePng(int width, int height, Uint8List rgb) {
  final raw = BytesBuilder(copy: false);
  final stride = width * 3;
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter: none
    raw.add(Uint8List.sublistView(rgb, y * stride, (y + 1) * stride));
  }
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> body) {
    final length = ByteData(4)..setUint32(0, body.length);
    final typed = [...ascii.encode(type), ...body];
    final crc = ByteData(4)..setUint32(0, _crc32(typed));
    out
      ..add(length.buffer.asUint8List())
      ..add(typed)
      ..add(crc.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2); // colour type: RGB
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder().convert(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

final _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
