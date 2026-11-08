#!/bin/bash
# Тести політик і логування без збірки під iOS.
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../.." && pwd)"
read -r -a cxx <<< "${CXX:-xcrun clang++}"
task_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/blinker-logic-tests.XXXXXX")"
gtest_root="$source_root/third_party/googletest/src/googletest"

for mode in enabled disabled; do
  defines=(-DBLINKER_HOST_TEST)
  if [[ "$mode" == disabled ]]; then
    defines+=(-DBLINKER_DISABLE_DIAGNOSTICS)
  fi
  "${cxx[@]}" -std=c++20 -I"$source_root" "${defines[@]}" \
    "$source_root/tools/blinker/diagnostics_test.cc" \
    -o "$task_test_dir/logging-$mode"
  "$task_test_dir/logging-$mode"
  printf 'Тести логування (%s) пройдено\n' "$mode"
done

"${cxx[@]}" -std=c++20 -pthread -I"$source_root" \
  -I"$gtest_root" -I"$gtest_root/include" \
  "$source_root/content/shell/common/blinker_site_policy_unittest.cc" \
  "$gtest_root/src/gtest-all.cc" "$gtest_root/src/gtest_main.cc" \
  -o "$task_test_dir/site-policy-tests"
"$task_test_dir/site-policy-tests"
printf 'Зібрані тести лежать в %s\n' "$task_test_dir"
