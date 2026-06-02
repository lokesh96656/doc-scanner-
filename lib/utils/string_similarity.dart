/// Levenshtein-based string similarity in the range 0.0–1.0.
double calculateStringSimilarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) {
    return 1.0;
  }
  if (a.isEmpty || b.isEmpty) {
    return 0.0;
  }

  final m = a.length;
  final n = b.length;
  final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));

  for (var i = 0; i <= m; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= n; j++) {
    dp[0][j] = j;
  }

  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      dp[i][j] = [
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + cost,
      ].reduce((value, element) => value < element ? value : element);
    }
  }

  final distance = dp[m][n];
  final maxLen = m > n ? m : n;
  return 1.0 - distance / maxLen;
}
