/// The runfiles paths of the files this library and the one under it need at
/// run time, each given to its library's `data`.
library;

export 'package:data_dep_inner/inner.dart' show innerFixture;

/// The runfiles path of the file `flutter_library.data` gives this library.
const flutterFixture = '_main/data_dep/flutter_fixture.txt';
