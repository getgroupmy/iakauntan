import 'dart:typed_data';

// What the web gets. ML Kit has no web implementation and will not
// acquire one — the model is a native library, and the package reaches
// `dart:io` to load it, so this file exists to keep the web build
// compiling rather than merely to fail politely at runtime.
bool get onDeviceReaderAvailable => false;

Future<String> readTextFromFile(String path) => throw UnsupportedError(
      'Reading on the device needs the phone or tablet app.',
    );

Future<String> readTextFromBytes(Uint8List bytes) => throw UnsupportedError(
      'Reading on the device needs the phone or tablet app.',
    );
