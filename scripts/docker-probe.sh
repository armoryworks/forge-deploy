# shellcheck shell=bash
# Not executable: this file is sourced, so it carries a shell directive
# rather than a shebang.
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

port_holder() {
    local port="$1" listing cname cports cproj seg hostpart lo hi
    listing=$(docker ps --format '{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}' 2>/dev/null || true)
    while IFS=$'\t' read -r cname cports cproj; do
        [[ -n "$cname" ]] || continue
        # Docker collapses consecutive mappings into ranges, so a container
        # publishing 9000 and 9001 reports "0.0.0.0:9000-9001->9000-9001/tcp".
        # Matching only the plain form made our own MinIO look like a stranger.
        local IFS=','
        for seg in $cports; do
            [[ "$seg" == *"->"* ]] || continue
            hostpart="${seg%%->*}"
            hostpart="${hostpart##*:}"
            hostpart="${hostpart//[[:space:]]/}"
            if [[ "$hostpart" == *-* ]]; then
                lo="${hostpart%%-*}"; hi="${hostpart##*-}"
                [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
                if (( port >= lo && port <= hi )); then
                    printf 'container %s %s' "$cname" "${cproj:-<none>}"; return 0
                fi
            elif [[ "$hostpart" == "$port" ]]; then
                printf 'container %s %s' "$cname" "${cproj:-<none>}"; return 0
            fi
        done
    done <<< "$listing"
    if [[ "${IS_MAC:-false}" == true ]]; then
        if lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null 2>&1; then
            printf 'process %s' "$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')"
        fi
        return 0
    fi
    local listeners; listeners="$(ss -tlnp 2>/dev/null || true)"
    if grep -q ":${port} " <<<"$listeners"; then
        local name; name=$(ss -tlnpH "sport = :${port}" 2>/dev/null | grep -oP '"\K[^"]+' | head -1 || true)
        printf 'process %s' "${name:-an unidentified process}"
    fi
}

# First free port at or above $1, skipping anything already spoken for.
next_free_port() {
    local p="$1" limit=$(( $1 + 200 ))
    while (( p < limit )); do
        [[ -z "$(port_holder "$p")" ]] && { printf '%s' "$p"; return 0; }
        p=$(( p + 1 ))
    done
    printf '%s' "$1"
}
