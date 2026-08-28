# Shared Docker reachability classifier. Sourced, never executed.
#
# This classification was written independently in setup.sh, refresh.sh, the
# recovery doctor and the console, and three of the four got the same detail
# wrong: `docker info 2>&1 | grep -q 'permission denied'` under `set -o pipefail`
# yields docker's exit status, not grep's result, so the permission branch is
# unreachable and every access problem is reported as a stopped daemon. The
# operator is then told to start a daemon that is already running.
#
# Capturing the output before matching is the entire fix, which is why it lives
# in one place now instead of four. Callers keep their own wording.
#
#   docker_state -> ok | absent | denied | stopped
#     ok      reachable by this user
#     absent  docker is not installed
#     denied  daemon is up; this account cannot use the socket (group membership)
#     stopped daemon is not running
docker_state() {
  command -v docker >/dev/null 2>&1 || { printf 'absent'; return 0; }
  if docker info >/dev/null 2>&1; then printf 'ok'; return 0; fi
  local out
  out=$(docker info 2>&1 || true)
  if grep -qi 'permission denied' <<<"$out"; then printf 'denied'; else printf 'stopped'; fi
}
