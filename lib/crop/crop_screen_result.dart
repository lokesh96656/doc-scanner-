import 'dart:io';

/// Returned from [CropDocumentScreen]: cropped file, retake raw capture, or cancel.
class CropScreenResult {
  const CropScreenResult({this.croppedFile, this.retakePhoto = false});

  final File? croppedFile;
  final bool retakePhoto;
}
