#!/usr/bin/env bash
set -euo pipefail

# Validate the public package surface from a fresh consumer project. The
# default path uses staged package directories so it does not depend on a
# package having been published yet. --hosted is used after publishing and
# resolves the exact version recorded in VERSION from pub.dev.
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ $# -le 1 ]] || { echo "usage: $0 [--hosted]" >&2; exit 2; }
mode="staged"
if [[ "${1:-}" == "--hosted" ]]; then
  mode="hosted"
elif [[ "${1:-}" != "" ]]; then
  echo "usage: $0 [--hosted]" >&2
  exit 2
fi

version="$(tr -d '[:space:]' < "$root_dir/VERSION")"
if [[ "$mode" == "hosted" ]]; then
  # pub.dev train only (excludes manual-only oka_process).
  package_list="$(dart "$root_dir/tool/release/train.dart" list --publish)"
else
  package_list="$(dart "$root_dir/tool/release/train.dart" list)"
fi
packages=()
while IFS= read -r package; do packages+=("$package"); done <<< "$package_list"
consumer_dir="$(mktemp -d "${TMPDIR:-/tmp}/oka-consumer.XXXXXX")"
trap 'rm -rf "$consumer_dir"' EXIT

if [[ "$mode" == "staged" ]]; then
  stage_dir="$consumer_dir/packages"
  mkdir -p "$stage_dir"
  for package in "${packages[@]}"; do
    mkdir -p "$stage_dir/$package"
    cp "$root_dir/packages/$package/pubspec.yaml" "$stage_dir/$package/"
    cp -R "$root_dir/packages/$package/lib" "$stage_dir/$package/"
    if [[ -d "$root_dir/packages/$package/bin" ]]; then
      cp -R "$root_dir/packages/$package/bin" "$stage_dir/$package/"
    fi
    sed -i.bak '/^[[:space:]]*resolution:[[:space:]]*workspace[[:space:]]*$/d' \
      "$stage_dir/$package/pubspec.yaml"
    rm -f "$stage_dir/$package/pubspec.yaml.bak"
  done
fi

mkdir -p "$consumer_dir/lib"
printf '%s\n' \
  'name: oka_standalone_consumer' \
  'environment:' \
  '  sdk: ^3.12.0' \
  'dependencies:' > "$consumer_dir/pubspec.yaml"
for package in "${packages[@]}"; do
  printf '  %s: %s\n' "$package" "$version" >> "$consumer_dir/pubspec.yaml"
done
if [[ "$mode" == "staged" ]]; then
  printf '%s\n' 'dependency_overrides:' >> "$consumer_dir/pubspec.yaml"
  for package in "${packages[@]}"; do
    printf '  %s:\n    path: packages/%s\n' "$package" "$package" >> "$consumer_dir/pubspec.yaml"
  done
fi

printf '%s\n' \
  "import 'package:oka/oka.dart';" \
  "import 'package:oka_android/oka_android.dart';" \
  "import 'package:oka_conformance/oka_conformance.dart' as conformance;" \
  "import 'package:oka_core/oka_core.dart' as core;" \
  "import 'package:oka_huawei/oka_huawei.dart';" \
  "import 'package:oka_play/oka_play.dart';" \
  "import 'package:oka_web/oka_web.dart';" \
  '' \
  'void acceptTypes(Oka _, ResolvedToolchain _, conformance.PublishPlan? _, core.BuildContext? _, HuaweiPublishTarget _, PlayPublishTarget _, core.Target _) {}' \
  'void main() {' \
  '  final Target target = const WebShellTarget(spec: WebShellSpec());' \
  "  final context = BuildContext.fromJson({'project_path': '.', 'build_dir': 'build', 'mode': 'debug', 'config': {}});" \
  '  acceptTypes(Oka(pipelines: const []), ResolvedToolchain(), null, context, HuaweiPublishTarget(), PlayPublishTarget(), target);' \
  '  final details = target.explainDetails(context);' \
  '  if (details.isEmpty) throw StateError("Target.explainDetails returned no details");' \
  '}' > "$consumer_dir/lib/main.dart"

pub_get_resolution_failed() {
  local output="$1"
  grep -qiE '(^|[[:space:]])version solving failed|could not find package|package not found|version .* not found|because .+ depends on .+ which doesn'\''t match|doesn'\''t exist on https://pub\.dev' <<<"$output"
}

run_consumer_project() {
  local pub_get_out pub_get_status
  pub_get_out="$(cd "$consumer_dir" && dart pub get --no-example 2>&1)" || pub_get_status=$?
  if [[ "${pub_get_status:-0}" -ne 0 ]]; then
    if pub_get_resolution_failed "$pub_get_out"; then
      echo "$pub_get_out" >&2
      return 2
    fi
    echo "$pub_get_out" >&2
    return 1
  fi
  (cd "$consumer_dir" && dart analyze && dart run lib/main.dart)
}

echo "Checking $mode consumer for oka $version"
if [[ "$mode" == "hosted" ]]; then
  retry_seconds="${OKA_HOSTED_CONSUMER_RETRY_SECONDS:-15}"
  retry_timeout="${OKA_HOSTED_CONSUMER_TIMEOUT_SECONDS:-600}"
  [[ "$retry_seconds" =~ ^[1-9][0-9]*$ && "$retry_timeout" =~ ^[1-9][0-9]*$ ]] || {
    echo "check_package_consumer: retry intervals must be positive integers" >&2
    exit 2
  }
  elapsed=0
  attempt=1
  backoff="$retry_seconds"
  while true; do
    set +e
    run_consumer_project
    status=$?
    set -e
    [[ "$status" -eq 0 ]] && exit 0
    [[ "$status" -ne 2 ]] && exit "$status"
    (( elapsed >= retry_timeout )) && {
      echo "check_package_consumer: hosted consumer failed after ${elapsed}s (pub.dev indexing lag?)" >&2
      exit 1
    }
    echo "check_package_consumer: attempt $attempt failed (pub get resolution); retrying in ${backoff}s (elapsed ${elapsed}s)" >&2
    sleep "$backoff"
    elapsed=$((elapsed + backoff))
    attempt=$((attempt + 1))
    backoff=$((backoff * 2))
    (( backoff > 60 )) && backoff=60
  done
else
  set +e
  run_consumer_project
  status=$?
  set -e
  exit "$status"
fi
