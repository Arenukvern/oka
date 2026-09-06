import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Abstract AI client interface.
//
// ignore: one_member_abstracts
abstract class AiClient {
  Future<String> complete(String prompt);
}

/// Apple Foundation Models client for macOS
class FoundationModelsClient implements AiClient {
  FoundationModelsClient();

  @override
  Future<String> complete(String prompt) async {
    // On macOS, we can use the native ML framework
    // For now, implementing a simple approach using Process to call MLX

    try {
      // Try to use mlx_lm if available for local inference
      final result = await Process.run(
        'python3',
        ['-m', 'mlx_lm.generate', '--prompt', prompt, '--max-tokens', '2000'],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        return result.stdout.toString();
      }

      // Fallback to Gemini if local model fails
      print('Foundation Models not available, falling back to Gemini');
      final geminiClient = GeminiClient();
      return await geminiClient.complete(prompt);
    } catch (e) {
      print('Foundation Models error: $e, falling back to Gemini');
      final geminiClient = GeminiClient();
      return await geminiClient.complete(prompt);
    }
  }
}

/// Google Gemini API client
class GeminiClient implements AiClient {
  final String? _apiKey;
  final String _model;

  GeminiClient({String? apiKey, String model = 'gemini-1.5-flash'})
      : _apiKey = apiKey ?? Platform.environment['GEMINI_API_KEY'],
        _model = model;

  @override
  Future<String> complete(String prompt) async {
    if (_apiKey == null || _apiKey.isEmpty) {
      throw Exception(
        'GEMINI_API_KEY environment variable not set. '
        'Get your API key from https://makersuite.google.com/app/apikey',
      );
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent?key=$_apiKey',
    );

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt}
            ]
          }
        ],
        'generationConfig': {
          'temperature': 0.2,
          'maxOutputTokens': 4096,
        },
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Gemini API error: ${response.statusCode} ${response.body}');
    }

    final json = jsonDecode(response.body);
    final candidates = json['candidates'] as List?;

    if (candidates == null || candidates.isEmpty) {
      throw Exception('No response from Gemini API');
    }

    final content = candidates[0]['content'];
    final parts = content['parts'] as List;

    if (parts.isEmpty) {
      throw Exception('Empty response from Gemini API');
    }

    return parts[0]['text'] as String;
  }
}

/// Factory to create the appropriate AI client
class AiClientFactory {
  static AiClient create({bool preferLocal = true}) {
    if (preferLocal && Platform.isMacOS) {
      return FoundationModelsClient();
    }
    return GeminiClient();
  }
}
