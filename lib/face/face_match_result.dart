/// Shared face comparison result for on-device and cloud providers.
class FaceMatchResult {
  const FaceMatchResult({
    this.matchPercent,
    this.pass,
    this.error,
    this.usedEmbeddingModel = false,
    this.distance,
    this.cosineSimilarity,
    this.provider,
  });

  final double? matchPercent;
  final bool? pass;
  final String? error;
  final bool usedEmbeddingModel;
  final double? distance;
  final double? cosineSimilarity;

  /// e.g. `MobileFaceNet`, `AWS Rekognition`.
  final String? provider;
}
