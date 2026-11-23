import 'dart:io';
import 'dart:typed_data';

/// Create a temporary file path where the native side can save a screenshot.
Future<String?> createScreenshotTempPath() async {
  try {
    final dir = await Directory.systemTemp.createTemp('rustdesk_chat_');
    return '${dir.path}/screenshot.png';
  } catch (_) {
    return null;
  }
}

/// Read the screenshot bytes saved by the native side, then clean up.
Future<Uint8List?> readTempFileBytes(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await deleteTempFile(path);
    return bytes;
  } catch (_) {
    return null;
  }
}

Future<void> deleteTempFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    final dir = file.parent;
    if (await dir.exists() && dir.path.contains('rustdesk_chat_')) {
      await dir.delete(recursive: true);
    }
  } catch (_) {}
}
