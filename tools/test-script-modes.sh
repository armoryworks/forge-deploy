#!/usr/bin/env bash
# test-script-modes.sh — every script the deploy tree runs is committed executable.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
PASS=0; FAIL=0

index_mode() { git -C "$REPO_ROOT" ls-files -s -- "$1" | awk '{print $1}'; }

expect_executable() {
  local path="$1" why="$2" mode
  mode=$(index_mode "$path")
  if [[ -z "$mode" ]]; then
    printf '  %s✗%s %s is not tracked (%s)\n' "$C_R" "$C_0" "$path" "$why"; FAIL=$((FAIL+1))
  elif [[ "$mode" != "100755" ]]; then
    printf '  %s✗%s %s is %s, not 100755 (%s)\n' "$C_R" "$C_0" "$path" "$mode" "$why"; FAIL=$((FAIL+1))
    printf '      fix: git update-index --chmod=+x %s\n' "$path"
  else
    printf '  %s✓%s %s\n' "$C_G" "$C_0" "$path"; PASS=$((PASS+1))
  fi
}

printf '%sScripts setup.sh runs%s\n' "$C_Y" "$C_0"
mapfile -t called < <(
  grep -vE '^[[:space:]]*(#|\. )' "$REPO_ROOT/setup.sh" \
    | grep -oE '(\$\(dirname[^)]*\)|\$\{?FORGE_TREE\}?)/[A-Za-z0-9_./-]+' \
    | sed -E 's#^[^/]*/##' | sort -u
)
if (( ${#called[@]} == 0 )); then
  printf '  %s✗%s found no script paths in setup.sh — the extraction is stale\n' "$C_R" "$C_0"; FAIL=$((FAIL+1))
fi
for path in "${called[@]}"; do
  expect_executable "$path" "setup.sh runs it"
done

printf '\n%sShebang scripts under scripts/%s\n' "$C_Y" "$C_0"
while IFS= read -r path; do
  head -c 2 "$REPO_ROOT/$path" | grep -q '^#!' || continue
  expect_executable "$path" "has a shebang"
done < <(git -C "$REPO_ROOT" ls-files -- 'scripts/*.sh' 'scripts/**/*.sh' | sort -u)

printf '\n──────────────────────────────\n'
printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" \
  "$( ((FAIL)) && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
(( FAIL == 0 ))
