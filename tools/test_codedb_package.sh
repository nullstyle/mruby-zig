#!/usr/bin/env bash
# Rehearse consuming a release archive and deploying only the installed files.
# Invoke through the pinned toolchain: mise x -- bash tools/test_codedb_package.sh
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
gem_preset=${1:-standard}
optimization=${2:-ReleaseSafe}
case "$gem_preset" in standard|minimal) ;; *) echo "expected standard or minimal" >&2; exit 2 ;; esac
case "$optimization" in Debug|ReleaseSafe) ;; *) echo "expected Debug or ReleaseSafe" >&2; exit 2 ;; esac
if (( $# > 2 )); then
  echo "usage: $0 [standard|minimal] [Debug|ReleaseSafe]" >&2
  exit 2
fi

zig_executable=$(command -v zig)
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/codedb-package.XXXXXX")
cleanup() {
  if [[ ${CODEDB_PACKAGE_KEEP_TMP:-0} == 1 ]]; then
    printf 'Package test files: %s\n' "$temp_root"
  else
    rm -rf -- "$temp_root"
  fi
}
trap cleanup EXIT

consumer="$temp_root/consumer"
archive="$temp_root/mruby-zig.tar.gz"
deployment="$temp_root/relocated install"
export ZIG_GLOBAL_CACHE_DIR="$temp_root/global-cache"
export ZIG_LOCAL_PKG_DIR="$temp_root/packages"
export ZIG_LOCAL_CACHE_DIR="$temp_root/build-cache"
mkdir -p "$consumer"

# Snapshot tracked and new nonignored files, including current edits. A clean
# CI checkout gives the release's Git contents. Nested fixture caches never
# enter the archive. Zig applies build.zig.zon's .paths when fetching it.
cd "$repo_root"
git ls-files -z --cached --others --exclude-standard --deduplicate |
  while IFS= read -r -d '' source_path; do
    if [[ -e "$source_path" || -L "$source_path" ]]; then
      printf '%s\0' "$source_path"
    fi
  done > "$temp_root/archive-files"
tar -czf "$archive" --null -T "$temp_root/archive-files"

for source_path in build.zig build.zig.zon main.zig config.rb init.rb job.rb worker.rb; do
  cp "$repo_root/tools/codedb_package_consumer/$source_path" "$consumer/$source_path"
done

cd "$consumer"
printf 'Fetching packaged mruby-zig with Zig %s\n' "$("$zig_executable" version)"
"$zig_executable" fetch --save=mruby_zig --pkg-dir "$ZIG_LOCAL_PKG_DIR" "$archive"
grep -qF '.hash =' build.zig.zon
if grep -qF '.path =' build.zig.zon; then
  echo 'package test must use a fetched archive, not a path dependency' >&2
  exit 1
fi
"$zig_executable" build -Dgem-set="$gem_preset" -Doptimize="$optimization" \
  --cache-dir "$ZIG_LOCAL_CACHE_DIR" --prefix "$temp_root/install" \
  -j"${CODEDB_PACKAGE_JOBS:-4}"

mv "$temp_root/install" "$deployment"
bash "$repo_root/tools/check_runtime_only_symbols.sh" \
  "$deployment/bin/codedb-package-consumer" "$deployment/bin/mruby-worker"

# Every build input and output cache was private to this test. Remove them,
# including downloaded dependencies, before launching the relocated program.
cd "$temp_root"
rm -rf -- "$consumer" "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR" \
  "$ZIG_LOCAL_PKG_DIR" "$archive" "$temp_root/archive-files"
mkdir "$temp_root/empty-working-directory"
cd "$temp_root/empty-working-directory"
"$deployment/bin/codedb-package-consumer"
printf 'Packaged deployment passed: %s / %s\n' "$gem_preset" "$optimization"
