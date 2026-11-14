import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/x11_screenshot.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// An X server that answers the handshake with one 4x2 screen and `GetImage`
/// with fixed pixels, and records what a client sent.
class FakeXServer {
  FakeXServer._(this._server);

  static Future<FakeXServer> start() async {
    final server = FakeXServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    // A client that gives up before the server has finished with it (a test
    // of a refused capture) ends the exchange; that is not a failure here.
    server._server.listen((client) => server._serve(client).catchError((_) {}));
    return server;
  }

  final ServerSocket _server;

  /// The authorisation name and data the client connected with.
  String? authName;
  List<int>? authData;

  /// What the server answers `GetImage` with instead of the pixels: an
  /// error code, when set.
  int? failWithError;

  /// Whether an event comes before the reply.
  bool eventFirst = false;

  /// The bytes per pixel the screen's format claims.
  int bitsPerPixel = 32;

  /// The red mask of the root visual.
  int redMask = 0xff0000;

  /// Refuse the connection with this reason.
  String? refuse;

  static const width = 4;
  static const height = 2;

  /// B, G, R, unused: the order of a 24-bit depth in 32-bit pixels.
  static Uint8List get pixels {
    final out = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      out[i * 4] = i * 10 + 3; // blue
      out[i * 4 + 1] = i * 10 + 2; // green
      out[i * 4 + 2] = i * 10 + 1; // red
    }
    return out;
  }

  /// The pixels as the PNG should hold them.
  static Uint8List get rgb {
    final out = Uint8List(width * height * 3);
    for (var i = 0; i < width * height; i++) {
      out[i * 3] = i * 10 + 1;
      out[i * 3 + 1] = i * 10 + 2;
      out[i * 3 + 2] = i * 10 + 3;
    }
    return out;
  }

  Future<void> close() => _server.close();

  int get port => _server.port;

  Future<void> _serve(Socket client) async {
    final buffer = BytesBuilder();
    final queue = StreamController<Uint8List>();
    client.listen(queue.add, onDone: queue.close);
    final reader = StreamIterator(queue.stream);
    Future<Uint8List> read(int n) async {
      while (buffer.length < n) {
        if (!await reader.moveNext()) throw StateError('client went away');
        buffer.add(reader.current);
      }
      final all = buffer.takeBytes();
      buffer.add(all.sublist(n));
      return all.sublist(0, n);
    }

    int pad(int n) => (n + 3) & ~3;
    final head = await read(12);
    final view = ByteData.sublistView(head);
    final nameLength = view.getUint16(6, Endian.little);
    final dataLength = view.getUint16(8, Endian.little);
    final name = await read(pad(nameLength));
    final data = await read(pad(dataLength));
    authName = ascii.decode(name.sublist(0, nameLength));
    authData = data.sublist(0, dataLength);

    if (refuse != null) {
      final reason = ascii.encode(refuse!);
      final reply = BytesBuilder()
        ..add([0, reason.length, 11, 0, 0, 0])
        ..add([pad(reason.length) ~/ 4, 0])
        ..add(reason)
        ..add(List.filled(pad(reason.length) - reason.length, 0));
      client.add(reply.takeBytes());
      await client.close();
      return;
    }

    const vendor = 'fake';
    final body = ByteData(
      32 + pad(vendor.length) + 8 + 40 + 8 + 24,
    );
    body.setUint16(16, vendor.length, Endian.little);
    body.setUint8(20, 1); // roots
    body.setUint8(21, 1); // formats
    body.setUint8(22, 0); // LSB first
    for (var i = 0; i < vendor.length; i++) {
      body.setUint8(32 + i, vendor.codeUnitAt(i));
    }
    var at = 32 + pad(vendor.length);
    body.setUint8(at, 24); // depth
    body.setUint8(at + 1, bitsPerPixel);
    at += 8;
    body.setUint32(at, 0x1234, Endian.little); // root window
    body.setUint16(at + 20, width, Endian.little);
    body.setUint16(at + 22, height, Endian.little);
    body.setUint32(at + 32, 0x21, Endian.little); // root visual
    body.setUint8(at + 38, 24); // root depth
    body.setUint8(at + 39, 1); // depths
    at += 40;
    body.setUint16(at + 2, 1, Endian.little); // one visual
    at += 8;
    body.setUint32(at, 0x21, Endian.little);
    body.setUint32(at + 8, redMask, Endian.little);
    body.setUint32(at + 12, 0x00ff00, Endian.little);
    body.setUint32(at + 16, 0x0000ff, Endian.little);
    final setup = BytesBuilder()
      ..add([1, 0, 11, 0, 0, 0])
      ..add(
        (ByteData(2)..setUint16(0, body.lengthInBytes ~/ 4, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(body.buffer.asUint8List());
    client.add(setup.takeBytes());

    final request = await read(20);
    expect(request[0], 73, reason: 'GetImage');
    expect(request[1], 2, reason: 'ZPixmap');
    final r = ByteData.sublistView(request);
    expect(r.getUint32(4, Endian.little), 0x1234, reason: 'the root window');
    expect(r.getUint16(12, Endian.little), width);
    expect(r.getUint16(14, Endian.little), height);

    if (eventFirst) client.add(Uint8List(32)..[0] = 2);
    if (failWithError != null) {
      client.add(
        Uint8List(32)
          ..[0] = 0
          ..[1] = failWithError!,
      );
    } else {
      final data = pixels;
      final reply = ByteData(32)
        ..setUint8(0, 1)
        ..setUint8(1, 24)
        ..setUint32(4, data.length ~/ 4, Endian.little);
      client.add(reply.buffer.asUint8List());
      client.add(data);
    }
    await client.flush();
    await reader.cancel();
  }
}

/// Decodes a PNG made of unfiltered RGB rows, checking each chunk's CRC.
({int width, int height, Uint8List rgb}) decodePng(Uint8List bytes) {
  expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final view = ByteData.sublistView(bytes);
  var at = 8;
  int? width, height;
  final idat = BytesBuilder();
  while (at < bytes.length) {
    final length = view.getUint32(at);
    final type = ascii.decode(bytes.sublist(at + 4, at + 8));
    final body = bytes.sublist(at + 8, at + 8 + length);
    final crc = view.getUint32(at + 8 + length);
    expect(crc, _crc(bytes.sublist(at + 4, at + 8 + length)), reason: type);
    if (type == 'IHDR') {
      width = ByteData.sublistView(body).getUint32(0);
      height = ByteData.sublistView(body).getUint32(4);
      expect(body.sublist(8), [8, 2, 0, 0, 0]);
    } else if (type == 'IDAT') {
      idat.add(body);
    }
    at += 12 + length;
  }
  final raw = ZLibDecoder().convert(idat.takeBytes());
  final stride = width! * 3;
  final rgb = BytesBuilder();
  for (var y = 0; y < height!; y++) {
    expect(raw[y * (stride + 1)], 0, reason: 'filter of row $y');
    rgb.add(raw.sublist(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
  }
  return (width: width, height: height, rgb: rgb.takeBytes());
}

/// A CRC-32 by the slow definition, so the encoder's table is checked
/// against something else.
int _crc(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xffffffff;
}

void main() {
  late Directory tmp;
  late FakeXServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('x11_screenshot_test_');
    server = await FakeXServer.start();
  });
  tearDown(() async {
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> capture(
    String output, {
    Map<String, String> environment = const {'DISPLAY': ':7'},
  }) => captureX11Screen(
    output,
    environment: environment,
    hostname: 'build-host',
    connect: (_) => Socket.connect(InternetAddress.loopbackIPv4, server.port),
  );

  group('X11Display.parse', () {
    test('reads local and remote display names', () {
      final local = X11Display.parse(':3.1');
      expect((local.number, local.screen, local.host), (3, 1, null));
      expect(local.socketPath, '/tmp/.X11-unix/X3');
      expect(X11Display.parse('unix:0').host, isNull);
      final remote = X11Display.parse('localhost:10.0');
      expect((remote.number, remote.host), (10, 'localhost'));
    });

    test('refuses a name that is no display', () {
      expect(() => X11Display.parse('wayland-0'), throwsFormatException);
    });
  });

  group('X11Authorization.find', () {
    Uint8List entry(
      int family,
      String address,
      String number,
      String name,
      List<int> data,
    ) {
      final out = BytesBuilder();
      void u16(int v) =>
          out.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
      void field(List<int> b) {
        u16(b.length);
        out.add(b);
      }

      u16(family);
      field(ascii.encode(address));
      field(ascii.encode(number));
      field(ascii.encode(name));
      field(data);
      return out.takeBytes();
    }

    test('takes the cookie of this host and display', () {
      final file = BytesBuilder()
        ..add(entry(256, 'other', '7', 'MIT-MAGIC-COOKIE-1', [1, 1]))
        ..add(entry(256, 'build-host', '8', 'MIT-MAGIC-COOKIE-1', [2, 2]))
        ..add(entry(256, 'build-host', '7', 'MIT-MAGIC-COOKIE-1', [3, 3]));
      final found = X11Authorization.find(
        file.takeBytes(),
        display: 7,
        hostname: 'build-host',
      );
      expect(found.name, 'MIT-MAGIC-COOKIE-1');
      expect(found.data, [3, 3]);
    });

    test('takes a wildcard entry, and none when nothing fits', () {
      final wild = entry(65535, '', '', 'MIT-MAGIC-COOKIE-1', [9]);
      expect(
        X11Authorization.find(wild, display: 4, hostname: 'x').data,
        [9],
      );
      final other = entry(256, 'other', '4', 'MIT-MAGIC-COOKIE-1', [9]);
      expect(
        X11Authorization.find(other, display: 4, hostname: 'x').name,
        isEmpty,
      );
    });
  });

  group('captureX11Screen', () {
    test(
      'writes the screen as a PNG, red and blue the right way round',
      () async {
        final output = p.join(tmp.path, 'shot.png');
        await capture(output);

        final png = decodePng(File(output).readAsBytesSync());
        expect(
          (png.width, png.height),
          (FakeXServer.width, FakeXServer.height),
        );
        expect(png.rgb, FakeXServer.rgb);
        expect(server.authName, isEmpty, reason: 'no Xauthority was given');
      },
    );

    test('opens the display with the cookie of the Xauthority file', () async {
      final auth = File(p.join(tmp.path, 'Xauthority'));
      final bytes = BytesBuilder();
      void u16(int v) =>
          bytes.add((ByteData(2)..setUint16(0, v)).buffer.asUint8List());
      void field(List<int> b) {
        u16(b.length);
        bytes.add(b);
      }

      u16(256);
      field(ascii.encode('build-host'));
      field(ascii.encode('7'));
      field(ascii.encode('MIT-MAGIC-COOKIE-1'));
      field([1, 2, 3, 4, 5]); // not a multiple of four: padded on the wire
      auth.writeAsBytesSync(bytes.takeBytes());

      await capture(
        p.join(tmp.path, 'shot.png'),
        environment: {'DISPLAY': ':7', 'XAUTHORITY': auth.path},
      );

      expect(server.authName, 'MIT-MAGIC-COOKIE-1');
      expect(server.authData, [1, 2, 3, 4, 5]);
    });

    test('skips an event that arrives before the image', () async {
      server.eventFirst = true;
      final output = p.join(tmp.path, 'shot.png');
      await capture(output);
      expect(decodePng(File(output).readAsBytesSync()).rgb, FakeXServer.rgb);
    });

    test('says there is no display when DISPLAY is unset', () {
      expect(
        capture(p.join(tmp.path, 'shot.png'), environment: const {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('DISPLAY'),
          ),
        ),
      );
    });

    test('reports a display that refuses the connection', () {
      server.refuse = 'Authorization required';
      expect(
        capture(p.join(tmp.path, 'shot.png')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Authorization required'),
          ),
        ),
      );
    });

    test('reports an error the server answers the capture with', () {
      server.failWithError = 8;
      expect(
        capture(p.join(tmp.path, 'shot.png')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('BadMatch'),
          ),
        ),
      );
    });

    test('refuses pixels it cannot read rather than writing a wrong image', () {
      server.bitsPerPixel = 16;
      expect(
        capture(p.join(tmp.path, 'shot.png')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('32-bit'),
          ),
        ),
      );
    });

    test('says so when the display cannot be reached', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
        captureX11Screen(
          p.join(tmp.path, 'shot.png'),
          environment: const {'DISPLAY': ':7'},
          connect: (_) => Socket.connect(InternetAddress.loopbackIPv4, port),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Cannot reach the X display'),
          ),
        ),
      );
    });
  });
}
