// How the suite reaches the host, and what the platform needs set up first,
// chosen by platform. On the VM it is the VM service; on the web, where there is
// none, it is hooks the host reaches over the browser's DevTools protocol.
export '_channel_io.dart' if (dart.library.js_interop) '_channel_web.dart';
