import 'dart:io';

import 'package:image/image.dart' as img;

/// Decodes a file and applies EXIF orientation so pixels match ML Kit landmark coords.
img.Image? loadOrientedImage(String path) {
  final bytes = File(path).readAsBytesSync();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return img.bakeOrientation(decoded);
}

img.Image flipHorizontal(img.Image source) {
  return img.flipHorizontal(source);
}
