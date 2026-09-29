#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${REPO_ROOT}/scripts/forge-deploy"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_0=$'\e[0m'
PASS=0; FAIL=0

scenario() { printf '\n%s%s%s\n' "$C_Y" "$1" "$C_0"; }
check() {
  if [[ "$2" == *"$3"* ]]; then
    printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1))
  else
    printf '  %s✗%s %s\n' "$C_R" "$C_0" "$1"; FAIL=$((FAIL+1))
  fi
}
check_not() {
  if [[ "$2" != *"$3"* ]]; then
    printf '  %s✓%s %s\n' "$C_G" "$C_0" "$1"; PASS=$((PASS+1))
  else
    printf '  %s✗%s %s\n' "$C_R" "$C_0" "$1"; FAIL=$((FAIL+1))
  fi
}

git_q() { git -c user.email=t@test -c user.name=test "$@"; }

build_install() {
  rm -rf "$SANDBOX/origin" "$SANDBOX/upstream" "$SANDBOX/install"
  mkdir -p "$SANDBOX/origin"
  git init -q --bare "$SANDBOX/origin"
  git -C "$SANDBOX/origin" symbolic-ref HEAD refs/heads/main

  git clone -q "$SANDBOX/origin" "$SANDBOX/upstream" 2>/dev/null
  mkdir -p "$SANDBOX/upstream/scripts"
  cp "$CLI" "$SANDBOX/upstream/scripts/forge-deploy"
  cp "${REPO_ROOT}/scripts/docker-probe.sh" "$SANDBOX/upstream/scripts/"
  chmod +x "$SANDBOX/upstream/scripts/forge-deploy"
  printf 'placeholder\n' > "$SANDBOX/upstream/setup.sh"
  printf 'image: pgvector/pgvector:pg17\n' > "$SANDBOX/upstream/docker-compose.yml"
  : > "$SANDBOX/upstream/docker-compose.prod.yml"
  git_q -C "$SANDBOX/upstream" add -A
  git_q -C "$SANDBOX/upstream" commit -qm init
  git_q -C "$SANDBOX/upstream" push -q origin HEAD:main

  git clone -q "$SANDBOX/origin" "$SANDBOX/install" 2>/dev/null
}

upstream_commit() {
  printf '%s\n' "$2" > "$SANDBOX/upstream/$1"
  git_q -C "$SANDBOX/upstream" add -A
  git_q -C "$SANDBOX/upstream" commit -qm "upstream change"
  git_q -C "$SANDBOX/upstream" push -q origin HEAD:main
}

run_update() {
  ( cd "$SANDBOX/install" \
    && FORGE_DEPLOY_REPO="$SANDBOX/install" FORGE_STATE_DIR="$SANDBOX/state" \
       "$SANDBOX/install/scripts/forge-deploy" --self-update "$@" ) < /dev/null 2>&1
}

printf '%sforge-deploy --self-update%s\n' "$C_Y" "$C_0"

scenario "A clean install just updates"
build_install
upstream_commit setup.sh "placeholder-v2"
OUT=$(run_update)
check "pulls"                "$OUT" "Pulled latest"
check "upstream landed"      "$(cat "$SANDBOX/install/setup.sh")" "placeholder-v2"

scenario "A hand-edited file blocks the update, and says what to do"
build_install
printf 'image: pgvector/pgvector:pg17\nnetworks:\n  custom: {}\n' > "$SANDBOX/install/docker-compose.yml"
OUT=$(run_update)
check "names the count"      "$OUT" "edited 1 file(s)"
check "names the file"       "$OUT" "docker-compose.yml"
check "offers to inspect"    "$OUT" "See exactly what changed"
check "offers to keep"       "$OUT" "--keep-local"
check "offers to discard"    "$OUT" "--discard-local"
check "changed nothing"      "$OUT" "Nothing was changed"
check "edit still present"   "$(cat "$SANDBOX/install/docker-compose.yml")" "custom"

scenario "--keep-local re-applies the edit on top of the update"
upstream_commit setup.sh "placeholder-v3"
OUT=$(run_update --keep-local)
check "saved a copy"         "$OUT" "Saved a copy"
check "re-applied"           "$OUT" "re-applied on top"
check "edit survived"        "$(cat "$SANDBOX/install/docker-compose.yml")" "custom"
check "upstream landed"      "$(cat "$SANDBOX/install/setup.sh")" "placeholder-v3"

scenario "A clash leaves a WORKING tree, not one full of conflict markers"
build_install
printf 'image: pgvector/pgvector:pg17\nmine: yes\n' > "$SANDBOX/install/docker-compose.yml"
upstream_commit docker-compose.yml "image: pgvector/pgvector:pg18"
OUT=$(run_update --keep-local)
check "says they clashed"    "$OUT" "clashed with the update"
check "points at the copy"   "$OUT" ".local-changes/"
check "gives the re-apply"   "$OUT" "git -C"
check_not "no markers left"  "$(cat "$SANDBOX/install/docker-compose.yml")" "<<<<<<<"
check "tree is at upstream"  "$(cat "$SANDBOX/install/docker-compose.yml")" "pg18"

scenario "--discard-local drops the edit but still keeps a copy"
build_install
printf 'image: pgvector/pgvector:pg17\njunk: from-troubleshooting\n' > "$SANDBOX/install/docker-compose.yml"
upstream_commit setup.sh "placeholder-v4"
OUT=$(run_update --discard-local)
check "saved first"          "$OUT" "Saved a copy first"
check_not "edit is gone"     "$(cat "$SANDBOX/install/docker-compose.yml")" "junk"
check "a copy remains"       "$(ls "$SANDBOX/install/.local-changes" | wc -l)" "1"

printf '\n──────────────────────────────\n'
printf '  %s%d passed%s   %s%d failed%s\n\n' "$C_G" "$PASS" "$C_0" \
  "$( ((FAIL)) && printf '%s' "$C_R" || printf '%s' "$C_G")" "$FAIL" "$C_0"
(( FAIL == 0 ))
