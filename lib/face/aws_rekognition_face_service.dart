import 'dart:io';
import 'dart:typed_data';

import 'package:aws_rekognition_api/rekognition-2016-06-27.dart';
import 'package:image/image.dart' as img;

import 'aws_rekognition_config.dart';
import 'face_image_utils.dart';
import 'face_match_result.dart';

/// Cloud face comparison using Amazon Rekognition CompareFaces.
class AwsRekognitionFaceService {
  Rekognition? _client;

  Rekognition get _rekognition {
    _client ??= Rekognition(
      region: AwsRekognitionConfig.region,
      credentials: AwsClientCredentials(
        accessKey: AwsRekognitionConfig.accessKeyId,
        secretKey: AwsRekognitionConfig.secretAccessKey,
      ),
    );
    return _client!;
  }

  void dispose() {
    _client?.close();
    _client = null;
  }

  Future<FaceMatchResult> compare({
    required String idImagePath,
    required String selfieImagePath,
  }) async {
    if (!AwsRekognitionConfig.isConfigured) {
      return const FaceMatchResult(
        error:
            'AWS credentials not configured. Add accessKeyId and secretAccessKey in lib/face/aws_rekognition_config.dart',
        provider: 'AWS Rekognition',
      );
    }

    try {
      final sourceBytes = await _readImageBytesForAws(idImagePath);
      final targetBytes = await _readImageBytesForAws(selfieImagePath);
      if (sourceBytes == null || targetBytes == null) {
        return const FaceMatchResult(
          error: 'Could not read image files for AWS Rekognition.',
          provider: 'AWS Rekognition',
        );
      }

      // Query with low threshold so AWS returns the actual similarity score.
      // ID portrait vs live selfie is often 60–75%, which would be hidden at 80%.
      final response = await _rekognition.compareFaces(
        sourceImage: Image(bytes: sourceBytes),
        targetImage: Image(bytes: targetBytes),
        similarityThreshold: AwsRekognitionConfig.apiQueryThreshold,
      );

      final sourceFace = response.sourceImageFace;
      if (sourceFace == null) {
        return const FaceMatchResult(
          error:
              'No face found on ID document. Crop closer to the portrait photo.',
          provider: 'AWS Rekognition',
        );
      }

      final matches = response.faceMatches ?? const [];
      if (matches.isEmpty) {
        return const FaceMatchResult(
          error:
              'No face found in selfie, or no similarity to ID portrait. Retake facing the camera.',
          provider: 'AWS Rekognition',
        );
      }

      final best = matches.first;
      final similarity = best.similarity ?? 0;
      final pass = similarity >= AwsRekognitionConfig.passThreshold;

      return FaceMatchResult(
        matchPercent: similarity,
        pass: pass,
        provider: 'AWS Rekognition',
      );
    } on InvalidParameterException {
      return const FaceMatchResult(
        error: 'AWS could not detect a face in the ID or selfie image.',
        provider: 'AWS Rekognition',
      );
    } on ImageTooLargeException {
      return const FaceMatchResult(
        error: 'Image is too large for AWS Rekognition (max 5 MB).',
        provider: 'AWS Rekognition',
      );
    } on AccessDeniedException {
      return const FaceMatchResult(
        error:
            'AWS access denied. Check IAM permissions for rekognition:CompareFaces.',
        provider: 'AWS Rekognition',
      );
    } on InvalidImageFormatException {
      return const FaceMatchResult(
        error: 'Unsupported image format. Use JPEG or PNG.',
        provider: 'AWS Rekognition',
      );
    } on ProvisionedThroughputExceededException {
      return const FaceMatchResult(
        error: 'AWS Rekognition rate limit exceeded. Try again shortly.',
        provider: 'AWS Rekognition',
      );
    } catch (e) {
      return FaceMatchResult(
        error: 'AWS Rekognition failed: $e',
        provider: 'AWS Rekognition',
      );
    }
  }

  /// Upright JPEG bytes (EXIF applied) for reliable AWS face detection.
  Future<Uint8List?> _readImageBytesForAws(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;

    final oriented = loadOrientedImage(path);
    if (oriented != null) {
      final jpeg = img.encodeJpg(oriented, quality: 92);
      if (jpeg.length > 5 * 1024 * 1024) {
        final smaller = img.copyResize(
          oriented,
          width: oriented.width > 1920 ? 1920 : oriented.width,
        );
        final compressed = img.encodeJpg(smaller, quality: 85);
        if (compressed.length <= 5 * 1024 * 1024) {
          return Uint8List.fromList(compressed);
        }
        throw Exception('Image exceeds AWS Rekognition 5 MB limit.');
      }
      return Uint8List.fromList(jpeg);
    }

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    if (bytes.length > 5 * 1024 * 1024) {
      throw Exception('Image exceeds AWS Rekognition 5 MB limit.');
    }
    return Uint8List.fromList(bytes);
  }
}
