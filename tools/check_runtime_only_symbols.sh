#!/bin/sh
# Inspect actual linked executables, including undefined references. `nm -P`
# is supported by GNU, LLVM, and macOS nm; normalize Mach-O's C symbol prefix.
# Keep the binary unstripped so a missing symbol table cannot produce a pass.
set -eu

if [ "$#" -eq 0 ]; then
  printf 'usage: %s executable [executable ...]\n' "$0" >&2
  exit 2
fi

symbols=$(mktemp)
trap 'rm -f "$symbols"' EXIT HUP INT TERM

for executable in "$@"; do
  "${NM:-nm}" -P "$executable" >"$symbols"
  awk -v executable="$executable" '
    {
      symbol = $1
      sub(/^_/, "", symbol)
      if (symbol == "mrb_vm_run" && $2 !~ /^[Uu]$/) vm = 1
      if (symbol == "mrz_set_sandbox_context" && $2 !~ /^[Uu]$/) hook = 1
      if (symbol ~ /^mrb_(parse|parser|ccontext)_/ ||
          symbol == "mrb_generate_code" ||
          symbol ~ /^mrb_load_(n?string|file)(_cxt)?$/ ||
          symbol == "mrb_load_detect_file_cxt" ||
          symbol == "mrb_load_exec" || symbol == "mrb_binding_eval" ||
          symbol ~ /^(GENERATED_TMP_)?mrb_mruby_eval_gem_(init|final)$/ ||
          symbol ~ /^mrz_protected_(compile|load_string)$/ ||
          symbol == "mrz_parse_nerr") {
        printf "%s: forbidden compiler symbol: %s\n", executable, symbol
        failed = 1
      }
    }
    END {
      if (!vm || !hook) {
        printf "%s: missing runtime VM/hook symbols; inspect an unstripped runtime executable\n", executable
        failed = 1
      }
      if (failed) exit 1
      printf "%s: runtime VM/hook symbols present; compiler symbols absent\n", executable
    }
  ' "$symbols"
done
