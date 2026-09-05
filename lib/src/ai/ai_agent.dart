import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:oka_core/src/config/dependency.dart';
import 'package:oka_core/src/config/manifest_merge_result.dart';
import 'package:oka_core/src/config/oka_config.dart';
import 'ai_client.dart';
import 'prompt_templates.dart';

/// AI agent for Gradle conversion and manifest merging
///
/// Uses Apple Foundation Models for macOS and Gemini as fallback.
/// Implements caching to avoid repeated API calls.
class OkaAiAgent {
  final AiClient _client;
  final String _cacheDir;

  OkaAiAgent(this._client, this._cacheDir);

  /// Convert Gradle build.gradle content to OkaConfig
  Future<OkaConfig> convertGradleToOka(
    String gradleContent,
    String projectPath,
  ) async {
    // Check cache first
    final cacheKey = _generateCacheKey(gradleContent);
    final cachedResult = await _loadFromCache(cacheKey, 'gradle_conversion');

    if (cachedResult != null) {
      print('Using cached Gradle conversion');
      return OkaConfig.fromJson(jsonDecode(cachedResult));
    }

    // Build prompt
    final prompt = PromptTemplates.gradleConversion(gradleContent, projectPath);

    // Call AI
    final response = await _client.complete(prompt);

    // Parse response
    final config = _parseGradleConversionResponse(response);

    // Cache result
    await _saveToCache(
        cacheKey, 'gradle_conversion', jsonEncode(config.toJson()));

    return config;
  }

  /// Extract dependencies from Gradle content
  Future<List<Dependency>> extractDependencies(String gradleContent) async {
    final cacheKey = _generateCacheKey(gradleContent);
    final cachedResult = await _loadFromCache(cacheKey, 'dependencies');

    if (cachedResult != null) {
      print('Using cached dependency extraction');
      final list = jsonDecode(cachedResult) as List;
      return list.map((e) => Dependency.fromJson(e)).toList();
    }

    final prompt = PromptTemplates.extractDependencies(gradleContent);
    final response = await _client.complete(prompt);

    final deps = _parseDependenciesResponse(response);

    await _saveToCache(
      cacheKey,
      'dependencies',
      jsonEncode(deps.map((d) => d.toJson()).toList()),
    );

    return deps;
  }

  /// Merge multiple AndroidManifest.xml files using AI
  Future<ManifestMergeResult> mergeManifests(
    List<String> manifestContents,
    MergeRules rules,
  ) async {
    if (manifestContents.isEmpty) {
      return ManifestMergeResult.fromJson({
        'merged_xml': '',
        'success': false,
        'errors': ['No manifests provided'],
      });
    }

    if (manifestContents.length == 1) {
      return ManifestMergeResult.fromJson({
        'merged_xml': manifestContents[0],
        'success': true,
        'errors': <String>[],
        'warnings': <String>[],
      });
    }

    final cacheKey = _generateCacheKey(manifestContents.join('\n---\n'));
    final cachedResult = await _loadFromCache(cacheKey, 'manifest_merge');

    if (cachedResult != null) {
      print('Using cached manifest merge');
      return ManifestMergeResult.fromJson(jsonDecode(cachedResult));
    }

    final prompt = PromptTemplates.manifestMerge(
      manifestContents[0],
      manifestContents.sublist(1),
      rules,
    );

    final response = await _client.complete(prompt);

    final result = _parseManifestMergeResponse(response, manifestContents);

    await _saveToCache(cacheKey, 'manifest_merge', jsonEncode(result.toJson()));

    return result;
  }

  /// Clear all AI conversion caches
  Future<void> clearCache() async {
    final cacheDirectory = Directory(_cacheDir);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
      print('AI cache cleared');
    }
  }

  // Private methods

  String _generateCacheKey(String content) {
    final bytes = utf8.encode(content);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<String?> _loadFromCache(String key, String category) async {
    final cachePath = p.join(_cacheDir, category, '$key.json');
    final file = File(cachePath);

    if (await file.exists()) {
      return await file.readAsString();
    }

    return null;
  }

  Future<void> _saveToCache(String key, String category, String content) async {
    final cachePath = p.join(_cacheDir, category, '$key.json');
    final file = File(cachePath);

    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  OkaConfig _parseGradleConversionResponse(String response) {
    try {
      // Extract JSON from response (AI might wrap it in markdown)
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(response);
      if (jsonMatch == null) {
        throw Exception('No JSON found in AI response');
      }

      final jsonStr = jsonMatch.group(0)!;
      final json = jsonDecode(jsonStr);

      return OkaConfig.fromJson(json);
    } catch (e) {
      throw Exception('Failed to parse Gradle conversion response: $e');
    }
  }

  List<Dependency> _parseDependenciesResponse(String response) {
    try {
      final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(response);
      if (jsonMatch == null) {
        throw Exception('No JSON array found in AI response');
      }

      final jsonStr = jsonMatch.group(0)!;
      final list = jsonDecode(jsonStr) as List<dynamic>;

      return list.map((dynamic e) => Dependency.fromJson(e)).toList();
    } catch (e) {
      throw Exception('Failed to parse dependencies response: $e');
    }
  }

  ManifestMergeResult _parseManifestMergeResponse(
    String response,
    List<String> sourcePaths,
  ) {
    try {
      // Extract XML from response
      final xmlMatch =
          RegExp(r'<manifest[\s\S]*</manifest>').firstMatch(response);

      if (xmlMatch == null) {
        return ManifestMergeResult.fromJson({
          'merged_xml': '',
          'success': false,
          'errors': ['No valid manifest XML found in AI response'],
          'source_paths': sourcePaths,
          'merge_strategy': 'ai',
        });
      }

      return ManifestMergeResult.fromJson({
        'merged_xml': xmlMatch.group(0)!,
        'success': true,
        'errors': <String>[],
        'warnings': <String>[],
        'source_paths': sourcePaths,
        'merge_strategy': 'ai',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      return ManifestMergeResult.fromJson({
        'merged_xml': '',
        'success': false,
        'errors': ['Failed to parse manifest merge response: $e'],
        'source_paths': sourcePaths,
        'merge_strategy': 'ai',
      });
    }
  }
}
