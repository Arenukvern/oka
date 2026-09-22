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
package_list="$(dart "$root_dir/tool/release/train.dart" list)"
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

echo "Checking $mode consumer for oka $version"
(cd "$consumer_dir" && dart pub get --no-example && dart analyze && dart run lib/main.dart)
