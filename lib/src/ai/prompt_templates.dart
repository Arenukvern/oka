import 'package:oka_core/src/config/manifest_merge_result.dart';

/// Prompt templates for AI agent operations
class PromptTemplates {
  /// Gradle to oka.yaml conversion prompt
  static String gradleConversion(String gradleContent, String projectPath) => '''
Convert this Gradle Android configuration to oka.yaml format.

Gradle file content:
```gradle
$gradleContent
```

Project path: $projectPath

Extract the following information:
- compileSdk, minSdk, targetSdk (from android block)
- package name / applicationId
- dependencies (format: group:artifact:version)
- source directories (if specified)
- versionCode and versionName
- ProGuard files (if any)

Return ONLY a valid JSON object matching this exact schema (no markdown, no explanation):
{
  "name": "project_name",
  "version": "1.0.0",
  "android": {
    "compile_sdk": "34",
    "min_sdk": "21",
    "target_sdk": "34",
    "package_name": "com.example.app",
    "application_id": "com.example.app",
    "version_code": 1,
    "version_name": "1.0.0",
    "source_dirs": ["src/main/java", "src/main/kotlin"],
    "res_dirs": ["src/main/res"],
    "enable_optimization": false,
    "proguard_files": [],
    "abis": ["arm64-v8a", "armeabi-v7a"]
  },
  "dependencies": [
    {"name": "group:artifact", "version": "1.0.0", "source": "maven"}
  ]
}

If a value is not found in the Gradle file, use sensible defaults:
- compileSdk: "34"
- minSdk: "21"
- targetSdk: "34"
- versionCode: 1
- versionName: "1.0.0"
- source_dirs: ["src/main/java", "src/main/kotlin"]
- res_dirs: ["src/main/res"]
- abis: ["arm64-v8a", "armeabi-v7a"]
''';
  }

  /// Extract dependencies from Gradle
  static String extractDependencies(String gradleContent) => '''
Extract all Android dependencies from this Gradle file.

Gradle content:
```gradle
$gradleContent
```

Look for dependencies in these blocks:
- implementation
- api
- compileOnly
- runtimeOnly

Return ONLY a valid JSON array (no markdown, no explanation):
[
  {"name": "androidx.core:core-ktx", "version": "1.10.0", "source": "maven"},
  {"name": "androidx.appcompat:appcompat", "version": "1.6.1", "source": "maven"}
]

Each dependency should have:
- name: in format "group:artifact"
- version: version string
- source: always "maven" for now

Exclude test dependencies (testImplementation, androidTestImplementation).
''';
  }

  /// Manifest merging prompt
  static String manifestMerge(
    String mainManifest,
    List<String> libraryManifests,
    MergeRules rules,
  ) {
    final librariesSection = libraryManifests
        .asMap()
        .entries
        .map((e) => 'Library ${e.key + 1}:\n```xml\n${e.value}\n```')
        .join('\n\n');

    return '''
Merge these Android manifest files following standard Android manifest merge rules.

Main application manifest (highest priority):
```xml
$mainManifest
```

$librariesSection

Merge rules:
1. Main app manifest attributes take priority over library manifests
2. Merge <uses-permission> elements, removing duplicates
3. Merge <uses-feature> elements, removing duplicates
4. Merge <application> attributes - main overrides library values
5. Combine all <activity>, <service>, <receiver>, <provider> declarations
6. Keep all <meta-data> elements from all manifests
7. If minSdkVersion conflicts, use the HIGHER value
8. If targetSdkVersion conflicts, use the value from main manifest

Return ONLY the merged manifest XML (no markdown blocks, no explanation).
Start with <?xml version="1.0" encoding="utf-8"?> and include the complete <manifest> element.
''';
  }

  /// Explain build error using AI
  static String explainError(String errorMessage, String context) => '''
A build error occurred in the Oka build system. Explain what went wrong and suggest fixes.

Error message:
$errorMessage

Context:
$context

Provide:
1. A brief explanation of what caused the error
2. Specific steps to fix the issue
3. Common mistakes that lead to this error

Keep the response concise and actionable.
''';
  }
}
