import 'package:flutter/widgets.dart';
import 'package:geolocator_apple/geolocator_apple.dart';

/// Shows what geolocator_apple, built for this app's environment, answers.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String location;
  try {
    location = (await GeolocatorApple().checkPermission()).name;
  } on Object catch (e) {
    location = '$e';
  }
  runApp(
    Center(
      child: Text('location: $location', textDirection: TextDirection.ltr),
    ),
  );
}
