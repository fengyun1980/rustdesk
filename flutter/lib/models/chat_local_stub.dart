import 'dart:typed_data';

// Web build placeholder: screenshots are not supported through the web bridge.
Future<String?> createScreenshotTempPath() async => null;

Future<Uint8List?> readLocalFileBytes(String path) async => null;

Future<Uint8List?> readTempFileBytes(String path) async => null;

Future<void> deleteTempFile(String path) async {}
