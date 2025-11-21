use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    // Get the target OS
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    if target_os == "android" {
        setup_android_build();
    }

    // Tell cargo to rerun this build script if certain files change
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=Cargo.toml");
}

fn setup_android_build() {
    // Try to find Flutter SDK
    if let Some(flutter_sdk) = find_flutter_sdk() {
        println!("cargo:rustc-env=FLUTTER_SDK={}", flutter_sdk.display());
        // Link Flutter engine libraries
        link_flutter_engine(&flutter_sdk);
    } else {
        println!("cargo:warning=Flutter SDK not found. This is OK if building without Flutter integration.");
    }

    // Note: Android SDK is now handled at the Dart level for cargo-apk
    // We don't require it here since cargo-apk will get it from environment variables
}

fn find_flutter_sdk() -> Option<PathBuf> {
    // Try FLUTTER_ROOT environment variable
    if let Ok(flutter_root) = env::var("FLUTTER_ROOT") {
        let path = PathBuf::from(flutter_root);
        if path.exists() {
            return Some(path);
        }
    }

    // Try to find flutter binary and derive SDK path
    if let Ok(flutter_output) = Command::new("flutter").arg("--version").arg("--machine").output() {
        if flutter_output.status.success() {
            if let Ok(json) = serde_json::from_slice::<serde_json::Value>(&flutter_output.stdout) {
                if let Some(flutter_root) = json.get("flutterRoot").and_then(|v| v.as_str()) {
                    return Some(PathBuf::from(flutter_root));
                }
            }
        }
    }

    // Try common locations
    let home = env::var("HOME").unwrap_or_default();
    let common_paths = vec![
        format!("{}/flutter", home),
        format!("{}/development/flutter", home),
        format!("{}/snap/flutter/common/flutter", home),
        "/opt/flutter".to_string(),
    ];

    for path_str in common_paths {
        let path = PathBuf::from(path_str);
        if path.exists() {
            return Some(path);
        }
    }

    None
}

fn find_android_sdk() -> Option<PathBuf> {
    // Try environment variables
    let env_vars = ["ANDROID_SDK_ROOT", "ANDROID_HOME"];

    for var in env_vars {
        if let Ok(sdk_path) = env::var(var) {
            let path = PathBuf::from(sdk_path);
            if path.exists() {
                return Some(path);
            }
        }
    }

    // Try common locations
    let home = env::var("HOME").unwrap_or_default();
    let common_paths = vec![
        format!("{}/Android/Sdk", home),
        format!("{}/Library/Android/sdk", home),
        "/opt/android-sdk".to_string(),
    ];

    for path_str in common_paths {
        let path = PathBuf::from(path_str);
        if path.exists() {
            return Some(path);
        }
    }

    None
}

fn link_flutter_engine(flutter_sdk: &PathBuf) {
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let target_abi = match target_arch.as_str() {
        "aarch64" => "arm64-v8a",
        "arm" => "armeabi-v7a",
        "x86" => "x86",
        "x86_64" => "x86_64",
        _ => "arm64-v8a", // default
    };

    // Flutter engine artifacts path
    let engine_artifacts = flutter_sdk.join("bin/cache/artifacts/engine");

    // Add Flutter engine library path
    let lib_path = engine_artifacts.join("android-arm64"); // cargo-apk handles ABI selection
    if lib_path.exists() {
        println!("cargo:rustc-link-search=native={}", lib_path.display());
    }

    // Link required Flutter engine libraries
    // Note: cargo-apk will handle most of the linking, but we can specify additional libs here
    println!("cargo:rustc-link-lib=dylib=flutter_engine");

    // Add ICU data path for runtime
    let icu_path = engine_artifacts.join("android-arm64/icudtl.dat");
    if icu_path.exists() {
        println!("cargo:icu_data={}", icu_path.display());
    }
}
