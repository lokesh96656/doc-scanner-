import 'dart:convert';

import 'package:flutter/services.dart';

String normalizeOcr(String s) {
  return s.replaceAll('\r', '\n').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

RegExp jsonRegex(String pattern, {bool defaultCaseSensitive = false}) {
  var p = pattern;
  var caseSensitive = defaultCaseSensitive;
  var multiLine = false;

  final m = RegExp(r'^\(\?([im]+)\)').firstMatch(pattern);
  if (m != null) {
    final flags = m.group(1)!;
    caseSensitive = !flags.contains('i');
    multiLine = flags.contains('m');
    p = pattern.substring(m.end);
  }

  try {
    return RegExp(p, caseSensitive: caseSensitive, multiLine: multiLine);
  } catch (_) {
    return RegExp(r'$.');
  }
}

class JsonTemplateEngine {
  JsonTemplateEngine(this.templates);

  final List<JsonTemplate> templates;

  static Future<JsonTemplateEngine> loadFromAssets() async {
    final raw = await rootBundle.loadString(
      'assets/templates/id_templates.json',
    );
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final list = (map['templates'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    final templates = list.map(JsonTemplate.fromJson).toList(growable: false);
    return JsonTemplateEngine(templates);
  }

  JsonTemplateResult detect(String ocrText) {
    final normalized = normalizeOcr(ocrText);
    final upper = normalized.toUpperCase();

    JsonTemplate? bestQualified;
    int bestQualifiedScore = -1;
    JsonTemplate? bestAny;
    int bestAnyScore = -1;
    for (final t in templates) {
      final score = t.score(upper);
      if (score > bestAnyScore) {
        bestAnyScore = score;
        bestAny = t;
      }
      if (score >= t.minScore && score > bestQualifiedScore) {
        bestQualifiedScore = score;
        bestQualified = t;
      }
    }

    final selected = bestQualified ?? (bestAnyScore >= 2 ? bestAny : null);
    if (selected == null) {
      return const JsonTemplateResult(
        displayName: 'Unknown',
        fields: {},
        valid: {},
      );
    }

    final fields = selected.extract(normalized);
    final valid = selected.validate(fields);
    return JsonTemplateResult(
      displayName: selected.displayName,
      fields: fields,
      valid: valid,
    );
  }
}

class JsonTemplateResult {
  const JsonTemplateResult({
    required this.displayName,
    required this.fields,
    required this.valid,
  });

  final String displayName;
  final Map<String, String> fields;
  final Map<String, bool> valid;
}

class JsonTemplate {
  JsonTemplate({
    required this.id,
    required this.displayName,
    required this.minScore,
    required this.keywordRules,
    required this.regexRules,
    required this.extractRules,
    required this.validateRules,
  });

  final String id;
  final String displayName;
  final int minScore;
  final List<JsonKeywordRule> keywordRules;
  final List<JsonRegexRule> regexRules;
  final Map<String, JsonExtractRule> extractRules;
  final Map<String, RegExp> validateRules;

  factory JsonTemplate.fromJson(Map<String, dynamic> j) {
    final detect = Map<String, dynamic>.from(j['detect'] as Map? ?? const {});
    final minScore = (detect['minScore'] as num? ?? 0).toInt();
    final keywords = (detect['keywords'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(
          (k) => JsonKeywordRule(
            text: k['text'] as String,
            weight: (k['weight'] as num).toInt(),
          ),
        )
        .toList(growable: false);
    final regex = (detect['regex'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(
          (r) => JsonRegexRule(
            re: jsonRegex(r['pattern'] as String),
            weight: (r['weight'] as num).toInt(),
          ),
        )
        .toList(growable: false);

    final extract = Map<String, dynamic>.from(j['extract'] as Map? ?? const {})
        .map(
          (k, v) => MapEntry(
            k,
            JsonExtractRule.fromJson(Map<String, dynamic>.from(v as Map)),
          ),
        );

    final validate =
        Map<String, dynamic>.from(j['validate'] as Map? ?? const {}).map(
          (k, v) => MapEntry(
            k,
            jsonRegex(Map<String, dynamic>.from(v as Map)['regex'] as String),
          ),
        );

    return JsonTemplate(
      id: j['id'] as String,
      displayName: j['displayName'] as String,
      minScore: minScore,
      keywordRules: keywords,
      regexRules: regex,
      extractRules: extract,
      validateRules: validate,
    );
  }

  int score(String upperText) {
    var s = 0;
    for (final k in keywordRules) {
      if (upperText.contains(k.text.toUpperCase())) s += k.weight;
    }
    for (final r in regexRules) {
      if (r.re.hasMatch(upperText)) s += r.weight;
    }
    return s;
  }

  Map<String, String> extract(String normalized) {
    final out = <String, String>{};
    for (final entry in extractRules.entries) {
      final v = entry.value.apply(normalized);
      if (v != null && v.trim().isNotEmpty) out[entry.key] = v.trim();
    }
    return out;
  }

  Map<String, bool> validate(Map<String, String> fields) {
    final out = <String, bool>{};
    for (final entry in validateRules.entries) {
      final v = fields[entry.key];
      if (v == null) continue;
      out[entry.key] = entry.value.hasMatch(v.trim());
    }
    return out;
  }
}

class JsonKeywordRule {
  const JsonKeywordRule({required this.text, required this.weight});
  final String text;
  final int weight;
}

class JsonRegexRule {
  const JsonRegexRule({required this.re, required this.weight});
  final RegExp re;
  final int weight;
}

class JsonExtractRule {
  JsonExtractRule({
    required this.re,
    required this.group,
    required this.fallbackGroup,
    required this.normalize,
  });

  final RegExp re;
  final int group;
  final int? fallbackGroup;
  final String? normalize;

  factory JsonExtractRule.fromJson(Map<String, dynamic> j) {
    return JsonExtractRule(
      re: jsonRegex(j['regex'] as String),
      group: (j['group'] as num?)?.toInt() ?? 0,
      fallbackGroup: (j['fallbackGroup'] as num?)?.toInt(),
      normalize: j['normalize'] as String?,
    );
  }

  String? apply(String text) {
    final m = re.firstMatch(text);
    if (m == null) return null;
    String? v = m.group(group);
    if ((v == null || v.isEmpty) && fallbackGroup != null) {
      v = m.group(fallbackGroup!);
    }
    if (v == null) return null;
    if (normalize == 'spaces_remove') {
      v = v.replaceAll(RegExp(r'\s+'), '');
    } else if (normalize == 'spaces_collapse') {
      v = v.replaceAll(RegExp(r'\s+'), ' ');
    }
    return v;
  }
}
