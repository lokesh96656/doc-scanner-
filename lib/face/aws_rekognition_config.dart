/// AWS Rekognition credentials.
///
/// **Local testing only** — paste keys below, then remove before release.
///
/// ## IAM policy (production)
///
/// This app only calls **CompareFaces** today. Minimum IAM policy:
///
/// ```json
/// {
///   "Version": "2012-10-17",
///   "Statement": [{
///     "Effect": "Allow",
///     "Action": "rekognition:CompareFaces",
///     "Resource": "*"
///   }]
/// }
/// ```
///
/// Grant additional actions only if you add those features later:
/// - `rekognition:DetectLabels`
/// - `rekognition:DetectFaces`
/// - `rekognition:RecognizeCelebrities`
/// - `rekognition:SearchFacesByImage`
class AwsRekognitionConfig {
  const AwsRekognitionConfig._();

  // Paste keys locally for testing only — keep empty in git.
  static const String accessKeyId = '';

  static const String secretAccessKey = '';

  static const String region = 'ap-south-1';

  /// Minimum similarity to show **Match** in the UI (same-person decision).
  static const double passThreshold = 80.0;

  /// API query threshold — use 0 so AWS returns the real score (e.g. ~68% for ID vs selfie).
  static const double apiQueryThreshold = 0.0;

  static bool get isConfigured =>
      accessKeyId.isNotEmpty && secretAccessKey.isNotEmpty;
}
