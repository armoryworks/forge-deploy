# Changelog

All notable changes to forge-deploy and its packaged images. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions track the deploy stack as a whole, not the individual app image tags.

## [0.8.9] - 2026-08-28

Field install, second machine. Setup got as far as starting containers and then
handed the operator three problems to solve by hand. It now solves all three
itself.

### Fixed

- **A second install came up against an empty database, silently.** `docker-compose.yml` pins `container_name`, so container names are global — but the compose *project* name defaults to the install directory, and volumes are project-prefixed. Installing to a different path therefore produced `<dir>_pgdata` instead of the existing `forge_pgdata`: a working Forge with none of the data in it. Fresh installs now pin `COMPOSE_PROJECT_NAME=forge`, so the data follows the install rather than the path. Written on `.env` **creation only** — adding it to an existing install would repoint every volume and read as total data loss.

- **A previous install's containers stopped setup dead.** Names being global, a stack from another project owning `forge`/`forge-api`/… is a conflict compose can neither rename nor adopt; the operator got raw daemon output about a name already in use. Setup now detects it, stops that stack (its volumes untouched), and **adopts its project name**, so this tree reuses its database and files. The install moves; the data stays put.

- **The port check named nothing and reassured wrongly.** It asked only `ss`, which cannot read another user's process names without root, then said *"if it's the previous Forge run, compose will rebind it; continuing"* — false whenever the holder belongs to anything else, which is exactly when it mattered. It asks Docker first now (which names every published mapping without root, and handles the collapsed `9000-9001->9000-9001` range form that made our own MinIO look like a stranger), and only claims a rebind when the holder really is this project. A conflict on `POSTGRES_PORT`, `API_PORT`, `UI_PORT` or the MinIO ports is moved to the next free port and recorded in `.env`; those mappings exist for host access only, so nothing but the address changes. If adopting a previous stack frees a port this run had moved on its account, it is moved back — but only ports this run moved, never one the operator chose.

  80 and 443 are deliberately excluded: they are the addresses people are told to browse to, and moving them silently would change the URL out from under the operator. `--public` still offers to stop nginx/apache.

### Changed

- `port_holder` and `next_free_port` live in `scripts/docker-probe.sh` beside `docker_state`, so port ownership is one implementation with direct tests (five assertions, including the range form) rather than logic buried in `setup.sh` where it could not be exercised.

## [0.8.8] - 2026-08-28

### Added

- **The reachability doctor is a console option.** `doctor.sh` — stack health, HTTPS, firewall, public IP, router/NAT, and whether the internet can actually reach the box — was only reachable as `./doctor.sh` or `setup.sh --doctor`, which is one more thing to remember than the one command is allowed to cost. It is now an entry in the guided menu: *"Forge runs here but people cannot reach it — find out why"*. It reads and reports, never changes anything, so it carries no confirmation gate. The console hands off to `doctor.sh` rather than reimplementing it, so there is one diagnosis to maintain. `--doctor` still works directly for scripts.

### Fixed

- The doctor exits non-zero when it finds problems, which under the console's `set -e` would have taken the console down before the status could be read. Captured with `|| rc=$?`.
- `tools/test-console.sh` picked menu entries by hardcoded number, so adding one silently moved every option below it — the quit scenario started selecting something else. Scenarios name the option they want now (`menu_number`), which is what stopped this change from breaking three of them invisibly. Five new assertions cover the doctor entry and its non-zero exit (52 total).

## [0.8.7] - 2026-08-28

The two structural pieces owed after six reactive releases: cover the sequence
that kept breaking, and sweep the defect class that kept reappearing.

### Added

- **`tools/test-install-e2e.sh` — the first install, end to end, in a container.** Every bug that reached an operator today lived between `npx` and a manageable stack, and neither existing suite touched either end of that. Twenty assertions across six scenarios drive `bin/install.mjs` on a clean `node:20-bookworm-slim` with `docker` stubbed per scenario: Docker absent, socket denied, daemon stopped, the artefacts a *failed* install leaves behind, whether printed instructions name their directory, and whether the documented command resumes the tree it abandoned. Wired into CI on push and into the release gate; skips with a message where containers cannot run.

  Verified by negative control rather than by assertion: pointed at `tags/v0.8.3` it fails on exactly the six things 0.8.4 fixed, and passes against `heads/main`. That control was earned — the first version of the suite reported 20/20 while testing nothing of the sort. `sudo -u op` resets the environment, so `FORGE_DEPLOY_REF` never reached the installer and it fell back to its pinned `DEFAULT_TREE_TAG`, quietly exercising the last *release* instead of the branch. It now forwards the ref explicitly and asserts that the ref it was given is the one fetched.

### Fixed

- **An active UFW firewall could be read as inactive, silently.** `sudo ufw status | head -1 | grep -qi "Status: active"` is the same pipefail trap as the Docker probe with an extra edge: `head -1` exits after one line, `ufw` dies of SIGPIPE, and the pipeline returns 141 — so whenever ufw's output outran the pipe buffer the match was discarded, setup concluded the firewall was inactive, and a `--public` install skipped opening 80/443 and came up unreachable with no warning. Captured once and matched three times now, which also stops shelling out to `sudo ufw` three times.
- **The port check discarded its own result the same way.** `ss -tlnp | grep -q ":${PORT} "` — `ss` can exit non-zero while still printing listeners, taking the match down with it and missing a genuine port conflict. Captured before matching.
- **`doctor.sh` reported a refused Docker socket as "the forge-ui container is not running".** `docker ps` returns nothing when the socket is denied, which is indistinguishable from a stopped stack, so the tool clients are told to run when something breaks sent them to restart a stack that was never the problem. It uses `docker_state` now and distinguishes absent, denied and stopped — the fifth and last caller to be folded in.

## [0.8.6] - 2026-08-28

Reported from the same box: `forge-deploy --recover` announced "Docker is
installed but not running — will start it" three times, each followed by a sudo
password failure, on a machine whose daemon was running the whole time.

### Fixed

- **The Docker probe was written four times and three copies were wrong.** `docker info 2>&1 | grep -qi 'permission denied'` under `set -o pipefail` reports docker's exit status, not grep's result, so the permission branch was unreachable and an inaccessible socket was always reported as a stopped daemon. 0.8.0 fixed the console's copy and 0.8.4 fixed setup.sh's; the recovery doctor's and refresh.sh's remained (refresh.sh never had a permission branch at all). Classification now lives in **`scripts/docker-probe.sh`** — `docker_state` → `ok | absent | denied | stopped` — sourced by all four callers, which keep their own wording. Four assertions drive it directly, including one under `set -o pipefail`, so the trap cannot be reintroduced per-copy.

- **The recovery doctor retried a fix that had already failed.** Each of its three passes re-ran `sudo systemctl start docker`, and with no controlling terminal sudo cannot prompt — so one refusal became three identical walls of error. A heal that fails is recorded and skipped on later passes, and a pass that fixes nothing ends the loop instead of running out its count. `sudo` for the daemon start is now checked for usability first: without a terminal and without cached credentials it says so and hands over the command, rather than failing opaquely.

- `scripts/forge-deploy` resolves the shared probe without calling `dirname`, since it is sourced before `PATH` can be trusted, and reports an incomplete deploy tree in a sentence if the file is missing.

## [0.8.5] - 2026-08-28

### Fixed

- **A dev checkout in the current directory could shadow the box's real install.** Discovery scanned every candidate for a *finished* install before considering unfinished trees, so precedence was decided by completeness rather than authority. Running the bare command from a forge-deploy source checkout — which has a `.env` and so reads as finished — opened the console on the checkout instead of the root recorded in `/etc/forge/deploy-state.json`, whose setup had not finished. The operator was then told "Forge has not been set up on this machine yet" about a directory that was never their install. `FORGE_DEPLOY_DIR` and the recorded root are statements of fact now: whichever is set is resolved on its own terms and outranks every guess, rather than merely sorting first among them. This also subsumes the vanished-root guard added in 0.8.4.

## [0.8.4] - 2026-08-28

Found by running the previous release on a real machine. All three failures hit
the same operator in the same sitting.

### Fixed

- **A Docker permission problem was reported as "the daemon is not running".** `setup.sh` matched with `docker info 2>&1 | grep -qi "permission denied"`, and under `set -o pipefail` a pipeline's status is the *last non-zero* one — docker's failure, not grep's result. The permission branch was unreachable, so every operator whose user wasn't in the `docker` group was told to `sudo systemctl start docker` for a daemon that was already running, and following that advice changed nothing. This is the identical bug fixed in the console's own probe in 0.8.0; this second copy was missed. Output is captured before matching now.

- **Instructions still named `./setup.sh` with no directory.** 0.8.3 fixed the closing banner and the notices but missed six more printed paths — including the one that matters most, the "After installing, close this terminal and re-run" that follows a failed prerequisite. The operator's shell is never in the tree when the bootstrapper ran setup, so `./setup.sh` reliably answered `No such file or directory`. Every printed instruction now carries `cd ${FORGE_TREE} &&`, in `setup.sh` and in `install-forge-deploy.sh`'s next steps.

- **An aborted setup could not be resumed by the documented command.** Discovery treated `.env` as the mark of a deploy tree, so a tree whose `setup.sh` had bailed on a prerequisite — the exact state a failed first run leaves behind — was invisible. With `/etc/forge` already written by the CLI installer, the bare command then reported "this machine has Forge configured, but its deploy tree is not in any of the places I looked" while the tree sat in the first place it looked. A *tree* (`setup.sh` + `scripts/forge-deploy`) is now distinguished from an *install* (a tree plus `.env`): a finished install opens the console, an unfinished one resumes setup in place. A finished install always wins over an unfinished one, and a recorded root that has vanished still refuses rather than adopting some unrelated tree found nearby.

### Added

- Eight assertions covering the resume path, install-beats-unfinished-tree, and the vanished-root refusal (26 total in `tools/test-install-discovery.sh`). The harness now distinguishes the two states the way the code does, and its `/opt` guard skips on any real deploy tree rather than only a configured one.

## [0.8.3] - 2026-08-28

### Fixed

- **The documented command told you it wasn't the documented command, then blocked.** `setup.sh` prints a notice pointing at the forge-deploy CLI whenever `FORGE_DEPLOY_CALLER` is unset — and the npm bootstrapper never set it. So `npx @armoryworks/forge-deploy`, the headline command in the README, printed "the supported way to install and manage Forge is the forge-deploy CLI" and then stopped on `read -rp "Press Enter to continue anyway"`. The bootstrapper sets the flag now; the notice is rewritten to point at `npx @armoryworks/forge-deploy` for anyone who really did run `setup.sh` by hand.

- **The npm path never installed the CLI, so `forge-deploy` didn't exist afterwards.** `bin/install.mjs` fetched the tree and ran `setup.sh`; nothing ever ran `scripts/install-forge-deploy.sh`, which is what creates `/etc/forge/deploy-state.json`, the log file, and `/usr/local/bin/forge-deploy`. A first install therefore ended with a running stack, no state file, and no command to manage it — the operator had to notice a shell script mentioned in passing. It now runs before `setup.sh`, so the state file exists while setup runs. A failure there warns and continues rather than aborting an otherwise good install.

- **The installed `forge-deploy` was hard-wired to `/opt/forge-deploy`.** `install-forge-deploy.sh` did `install -m 0755 <tree>/scripts/forge-deploy /usr/local/bin/forge-deploy` — a blind copy recording nothing about its origin, and a copy on `PATH` has no tree around it to resolve from. An install at `~/forge-deploy` or `/srv/forge` got a CLI silently reading a different install's `.env`, compose files and overrides. It now installs a two-line wrapper that exports `FORGE_DEPLOY_REPO=<the tree it was run from>` and execs that tree's CLI — which also means refreshing the tree updates the command, instead of leaving a frozen copy to drift from what it manages. The tree root is written to `.box.repoRoot` at the same time, so the bare command can find it immediately.

- **Every command `setup.sh` printed assumed you were standing in the deploy tree.** It had no `SCRIPT_DIR` and no `cd` — ten printed instructions (`docker compose logs -f forge-api`, `./refresh.sh`, `scripts/install-forge-deploy.sh`, …) were relative to the caller's cwd. Run through the bootstrapper that is never the operator's shell: setup.sh gets the tree as its cwd while the operator's shell stays where they typed `npx`, so every one of them failed on paste. `FORGE_TREE` is resolved from `BASH_SOURCE` now; the "Useful Commands" block leads with the `cd` that makes the rest true, and the notices name absolute paths.

### Added

- **`FORGE_INSTALL_PREFIX` relocates everything `install-forge-deploy.sh` writes** (`/usr/local/bin`, `/etc/forge`, `/var/log`) and suppresses the sudo auto-elevation, which is what makes that script exercisable without root — and so testable at all. Six new assertions in `tools/test-install-discovery.sh` cover the wrapper, the recorded root, that the installed command resolves to its own tree, and that the bare command then discovers it (21 total). They skip with a message when jq is unavailable.

## [0.8.2] - 2026-08-28

### Fixed

- **`test-console.sh`'s jq scenario only tested anything on a machine without jq.** The harness put the sandbox stubs ahead of the real `PATH` rather than replacing it, so removing `$SANDBOX/bin/jq` still left `/usr/bin/jq` findable — the assertion passed on a developer box (no jq installed) and failed the moment it ran in CI (jq installed). Scenarios can now narrow the console's `PATH` to the sandbox alone.
- `tools/test-install-discovery.sh` pins `HOME` into the sandbox and skips its fresh-machine scenario on a box with a real install under `/opt`, so neither can turn a legitimate discovery hit into a failure.

## [0.8.1] - 2026-08-28 — WITHDRAWN

The `v0.8.1` tag was pushed before CI reported on its commit, and the release
workflow — which had no test gate — published a GitHub release from a tree whose
suite was red. Tag and release are both deleted, and the workflow is gated now.
Nothing consumed it: `@armoryworks/forge-deploy@0.1.7` pinned `v0.8.0`
throughout, and `0.1.8` pins `v0.8.2`. **Everything below shipped in `v0.8.2`**,
and is kept under its own heading because the work, not the tag, is what these
entries describe.

### Fixed

- **The bare command found the install only if you were standing next to it.** `npx @armoryworks/forge-deploy` with no arguments defaulted its target to `./forge-deploy`, so a client who typed it from `$HOME` on a box deployed at `/opt/forge-deploy` was handed the *first-install wizard* — the single worst thing this tool can do on a live machine. The no-argument form now locates the tree (recorded root, then the current directory, `./forge-deploy`, `/opt/forge-deploy`, `/opt/forge`, `~/forge-deploy`; `FORGE_DEPLOY_DIR` overrides) and opens the console on it **in place**, with no download — re-extracting over a root-owned install would have failed for exactly the operator the console exists for. If the state file says this box is configured but no tree can be found, it refuses and asks for the directory rather than installing a second Forge beside the first. Any argument at all — a directory, a subcommand, a setup flag — means the caller has already said what they want, and nothing is searched.

- **The deploy CLI operated on `/opt/forge-deploy` no matter where it was run from.** `REPO_ROOT` fell back to that path whenever `FORGE_DEPLOY_REPO` was unset, so a copy invoked out of `<tree>/scripts` read another install's `.env`, compose files, and overrides. Combined with the bug above, the console could report on one tree while the bootstrapper had verified a different one. A copy that still sits in a deploy tree (`docker-compose.yml` and `.env.example` beside it) now resolves to that tree; the copy installed at `/usr/local/bin` has no tree around it and keeps the `/opt/forge-deploy` default. The bootstrapper and `panel/server.mjs` also name the root explicitly on every hand-off.

### Added

- **`.box.repoRoot` in the deploy state file** — written on setup, on every deploy, and opportunistically when the console opens, so the lookup above is exact rather than a search. An install predating the recording is healed the first time its console is opened.
- **`tools/test-install-discovery.sh`** — 15 assertions over the bootstrapper's no-argument path, driven against stub trees with the network ref pointed at a tag that cannot exist, so every scenario also proves no fetch occurred.
- `FORGE_STATE_DIR` is honoured by `bin/install.mjs` as well as the CLI, so the bootstrapper can be exercised outside `/etc`.

### Note

The `v0.8.0` tag was cut one commit before the jq/curl guard listed under 0.8.0 below; `v0.8.2` is the first tree that actually carries it.

## [0.8.0] - 2026-08-27

### Added

- **The guided console — `forge-deploy` with no arguments.** The whole customer-facing surface is now one command that takes no flags and assumes no knowledge of the deploy model. It reads the machine, reports what is installed and whether it is healthy in plain language, says whether a newer release exists, and offers a short numbered menu with exactly one entry marked *(recommended)*. Every action is the same gated path the flags drive — the console cannot skip a gate. It covers every state of a box: never bootstrapped, installed but with no role chosen, unhealthy, behind, or current. On a machine that is not a terminal it prints the picture and the non-interactive command instead of hanging.

- **A stale installer is offered as the first step, not forced.** The console compares the npm package that delivered this tree (recorded in `.installer-version` at fetch time) against what `@armoryworks/forge-deploy` publishes now. If it is behind, that becomes menu entry 1 and carries the recommendation, because updating the tool may fix whatever else is wrong. Choosing it fetches the new installer and reopens the console automatically. The `exec` happens *before* the download for a reason documented at the call site: bash reads a script incrementally, and the fetch overwrites the file the function is running from.

- **`tools/test-console.sh`** — 47 assertions across 17 scenarios, driving the console on a real pty with `docker`, `curl`, `npx` and `sudo` all stubbed, so every branch runs on a machine with no Docker daemon at all. This is the first automated coverage of any interactive path in this repo, and it caught two real bugs on its first run (both fixed below). `FORGE_TEST_SHOW=1` prints each screen in full.

- `forge-deploy --pick` preserves the old bare-invocation behaviour (per-component release picker) as operator tooling.

### Changed

- `main()` no longer branches on zero-args before flag parsing (recovery doctor / setup wizard / version picker). Every one of those states is a menu entry in the console now, and the pre-emptive `preflight` that could `die()` in front of a client is gone.
- The npm bootstrapper opens the console on a box that is already configured, instead of re-running `setup.sh`. `npx @armoryworks/forge-deploy` is now the single command worth remembering.
- `STATE_DIR` and `LOG_FILE` honour `FORGE_STATE_DIR` / `FORGE_LOG_FILE`, so the tooling can be exercised outside `/etc` and `/var/log`.
- `docs/DEPLOY.md` §12 leads with the console; the operator flags follow it.

### Fixed

- **A Docker permission error was reported as "Docker is not running".** `docker info 2>&1 | grep -q 'permission denied'` under `set -o pipefail` returns the failure of `docker`, not the result of `grep`, so the branch could never be reached — every permission problem produced advice to start a daemon that was already running. Output is captured before matching now. Found by the new harness.
- **The menu could abort the script before printing.** Labels were built with `"…$( [[ cond ]] && printf ' (recommended)' )"`; when the condition was false the command substitution returned non-zero and `set -e` took the console down mid-render. Rebuilt with explicit `if` blocks, and the recommendation is now assigned once by urgency.
- **A box with no `jq` was reported as never configured, with the setup wizard as the recommendation.** Dropping `preflight` from the bare path (so it could not `die()` in front of a client) also dropped the guarantee that `jq` and `curl` exist. Every state read on the console screen goes through `jq`, so without it `.box.role` came back empty and a working install was offered a re-run of the topology wizard. The console now checks both helpers first and prints install commands — the repair path needs `jq` too, so there is nothing else it could honestly offer. Found on the first run against a real Docker daemon.
- `console_menu` retries are bounded at three: a closed stdin or a stuck key can no longer leave the tool spinning on a client's server.
- **`docs/DEPLOY.md` "Rollbacks" still described EF Core auto-migrations** — retired 2026-06-17 — five weeks after the Upgrades section next to it was corrected for the same reason. Rewritten: the automatic rollback covers the health-gate failure, manual rollback needs the pre-reconcile dump restored, and `SCHEMA_IMAGE_TAG` must be re-pinned with the image tags or the next deploy re-applies what was backed out. The matching *Known issues* entry above is corrected too.

## [0.7.0] - 2026-08-27

### Changed

- **The npm bootstrapper now fetches a PINNED release tree, not `main`** (`bin/install.mjs`). `TARBALL_URL` resolved `refs/heads/main`, so a client running `npx @armoryworks/forge-deploy upgrade` received whatever had landed on main minutes earlier — the deploy CLI, every compose file, and setup.sh included. Pinning the npm version only ever pinned the ~50-line bootstrapper. The tree ref is now `v0.7.0`; a missing tag is a hard failure with an explanatory message, never a silent fall back to main. `FORGE_DEPLOY_REF` (`heads/main`, `tags/vX.Y.Z`, or a bare tag) overrides it for development.

- **`--allow-destructive` is refused on customer-operated installs.** New `.env` key `SUPPORT_CONTACT`: when set, a reconcile that would drop data still halts and enumerates, but names the contact instead of printing the flag that bypasses the halt, and passing the flag is an error. The disposition prompt ("1 - ok to delete / 2 - cannot until x,y,z / 3 - cannot delete") is addressed to whoever can price the loss; the operator in front of a client box is not that person. Unset (the default) preserves the existing behaviour exactly.

- `tools/forge-upgrade.sh` no longer prints the `--allow-destructive` re-run command as unconditional trailing boilerplate after *every* run, successful or not.

### Added

- **`npx @armoryworks/forge-deploy recover [dir]`** — the doctor (`forge-deploy --recover`) was unreachable from the npm path: in `upgrade` mode flags are appended to `--update` (so `upgrade --recover` became `--update --recover`), and the plain path hands off to `setup.sh`. It is the tool most useful to an operator working alone. Unlike `upgrade` it does not require a configured box — a half-finished install is what it exists for.

- **Node version gate before the implementation loads** (`bin/forge-deploy.mjs` is now a shim over `bin/install.mjs`). `fetch` and `Readable.fromWeb` fail on Node < 18 as a bare `ReferenceError` naming neither Node nor the version; `engines` only makes npm warn. The shim contains nothing newer than dynamic `import()`, checks the major version, and prints install instructions.

## [Unreleased]

### Fixed

- **`--lan` now fully recovers an install that was flipped by `--public`** (field incident, 2026-08-25: a LAN appliance re-run with `--public` left LAN clients on *connection refused* even after `--lan --no-ssl`, with all containers "healthy"). Three healing changes: (1) LAN mode normalizes a leftover `UI_PORT=4200` back to `80` on every run (the dev default is not an operator choice; genuinely custom ports are preserved) — previously the 4200→80 rewrite only ran on a fresh `.env`, so the recovery run advertised/bound the wrong port; (2) a stale **auto-generated** `docker-compose.override.yml` (e.g. the SSL override from a `--public` run) is deleted once no override is needed — it kept auto-loading in `--source` mode and made the exposure inference read the install as "public" forever (hand-written overrides, without the generation marker, are untouched); (3) after starting a LAN install, setup.sh now **probes the advertised `FRONTEND_BASE_URL`** and prints an explicit warning with `ss`/`UI_BIND`/`UI_PORT` guidance when nothing answers — container health alone never verified that the UI was published on the right host port/interface.

### Added

- **Exposure-change guard**: running `--public` against an existing install recorded as `--lan`/`--local` now requires typing `PUBLIC` at an interactive prompt (or passing the new `--confirm-exposure-change` flag in scripts). The prompt spells out the consequences — UI moves to self-signed HTTPS on 80/443, base URL/CORS rewritten away from the LAN address, preflight may stop host services and open UFW. Prevents the habit-run that took a customer LAN site down.

- **setup.sh died silently at the port check when re-run over a live stack as a non-root user** (field report, 2026-07-20). Non-root `ss` can't read root-owned process names (e.g. docker-proxy from the running stack), so the holder-name `grep` matched nothing and its pipefail status killed the script under `set -e` — no error, no output, right after the disk-space check. The port check now tolerates unidentifiable holders (warns and continues; a genuine conflict still surfaces at `compose up` with a clear "port is already allocated"). Same guard applied to the `--public` preflight's `port_listener()` and the `UI_PORT` reads.

### Added

- **Deployment targets in setup.sh: local / LAN / public** (`dbcf025`). Interactive first-time runs with no mode flags are asked "How will people reach this Forge install?"; the answer persists in `.env` (`QBE_DEPLOY_TARGET`) so re-runs never re-ask. New flags: `--lan` (turnkey LAN install — standalone, no TLS, UI bound `0.0.0.0`, `FRONTEND_BASE_URL` / `CORS_ORIGINS` / `MINIO_PUBLIC_ENDPOINT` pointed at the host's LAN IP) and `--local` (explicit localhost-only). `--lan` also converts an existing install in place, which fixes the field-reported failure where the headless auto-SSL default pinned `4200` to loopback and LAN clients got *connection refused*. Final banner now prints the port-correct URL other PCs should use. Documented in `docs/DEPLOY.md` §6 and `docs/TROUBLESHOOTING.md` › Network access (LAN).

## [0.6.1] - 2026-07-16

### Fixed

- **SSL install was broken on every fresh box, two ways** (found on a clean Ubuntu 24.04 install, 2026-07-16). (1) *Double-publish of host 443*: setup.sh set `UI_PORT=443` while the generated override also published `443:443`; compose merges port lists, so the container tried to bind host 443 twice and died with "port is already allocated" — with nothing listening, which made it look like phantom daemon state. setup.sh no longer touches `UI_PORT`; the override solely owns 443/80 and the plain-HTTP 4200 mapping is pinned to loopback (`UI_BIND=127.0.0.1`) so TLS can't be bypassed from the network. (2) *`forge-ui/nginx-ssl.conf` was referenced but never shipped*: docker silently auto-created the mount source as an empty root-owned directory, then failed with "not a directory: are you trying to mount a directory onto a file?". The file (canonical source: forge-ui repo) is now tracked in this repo, setup.sh verifies it and removes phantom directories, and the port-80 server exempts the loopback healthcheck from the HTTPS redirect (a blanket 301 made `wget --spider http://127.0.0.1:80/` fail, so the container never went healthy).
- setup.sh pre-creates `./backups` and `./certs` so docker doesn't auto-create them root-owned.
- `--recover` detects and heals both SSL failure states (`sslports`, `sslconf` — restores the config from git), and now distinguishes "daemon not running" from "your user can't access the docker socket" (plain-language usermod + re-login guidance).
- setup.sh notes the missing-buildx Bake warning once (`sudo apt install -y docker-buildx`) instead of letting compose print a scary warning mid-build.

### Added

- **`forge-deploy` is now the single user-facing entry point** (forge-deploy `0.6.0`). A no-arg run on a never-bootstrapped box routes through the new **recovery doctor**, which runs the first-time bootstrap (delegating to `setup.sh` internally via `FORGE_DEPLOY_CALLER=1`) and then the topology wizard — users never invoke `setup.sh` directly anymore (direct runs print a deprecation pointer and continue).
- **`forge-deploy --recover` (alias `--doctor`)** — declarative state scan that detects common failure modes and the incomplete setups they leave behind: Docker missing/stopped, snap-Docker-on-cgroup-v2 packaging, missing Compose plugin, incomplete repo clone, missing/unwritable/outdated `.env` (merges new `.env.example` keys), placeholder JWT key, unpinned or `latest` image tags, uninstalled CLI state, stopped or crash-looping containers, and port conflicts (named in plain language, never blind-killed). Fixable items heal in place across up to 3 scan→heal passes, then the run health-gates on `forge-api`. Known API-log signatures (bad DB password, unreachable remote DB/storage, GHCR unauthorized) get plain-language explanations.
- **`forge-deploy --fresh-start`** — the rm-rf path: after a typed `FRESH` confirmation, tears down all Forge containers and volumes (database + uploaded files), removes generated config (`.env`, certs, overrides, box scope), resets the recorded role, and re-runs setup from scratch. Works from broken/partial states (belt-and-braces `docker rm -f` fallback when compose can't resolve).
- **Unrecoverable-issue reporting** — when recovery hits something it can't fix or identify, it explains the situation in plain language (no log dumps), prints a prefilled GitHub issue URL, and — if a `gh` login is present — offers to auto-file the issue with sanitized, secret-free diagnostics (`.env` is never included; log tails are credential-scrubbed).

### Changed

- **`forge-deploy --list` now pairs each version with its build-sha** (forge-deploy `0.2.0`). The default view resolves the manifest digest of every recent `X.Y.Z` tag and every `main-<sha>` tag (in parallel via `xargs -P`), groups by digest — they share one digest because the release-manifest workflow stitches all tags onto a single manifest list — and prints `0.0.115  (main-972e58a)  ← latest`. `--list --releases` and `--list --builds` give the old single-column views. Version sort fixed to `sort -Vr` so `0.0.115` ranks above `0.0.9` (plain `sort -r` ordered them wrong). `ghcr_list_tags` now follows GHCR pagination so images with 100+ accumulated tags aren't truncated to the first page.

### Added

- **GHCR Basic-auth support in `forge-deploy`** for the window where the `forge-*` container packages are still private. Reads `GHCR_USER` + `GHCR_TOKEN` from the environment, or from `${STATE_DIR}/ghcr-user` + `ghcr-token` written by `install-forge-deploy.sh` (`sudo GHCR_USER=… GHCR_TOKEN=ghp_… ./scripts/install-forge-deploy.sh`). Falls back to anonymous token requests for public images, so no change is needed once the packages are flipped to public. Per-repo token caching added so the parallel digest resolution doesn't re-mint a token per request.
- `docs/DEPLOY.md` — canonical install runbook covering Pi 5 / Ubuntu Server arm64 + Cloudflare Tunnel topology.
- `docs/TROUBLESHOOTING.md` — symptom/cause/fix catalog covering host setup, image pull, stack startup, runtime, and ingress issues encountered in real deploys.
- `CHANGELOG.md` (this file).

### Fixed

- **`forge-api` DI lifetime bug** (forge-api `690c921`). `Forge.Core.Interfaces.IStorageService` was registered as singleton but consumed `Forge.Core.Settings.ISettingsService` (scoped), causing startup validation failure (`ValidateScopes=true`) and a container restart loop. Approximately 20 MediatR handlers were transitively affected, including `UploadLogoHandler`, `DeleteLogoHandler`, `DeleteLockupHandler`, and `HandleDocuSealWebhookHandler`. Fix delivered in `ghcr.io/armoryworks/forge-api:latest` (multi-arch arm64 + amd64).
- **`forge-storage` (MinIO) healthcheck added to `docker-compose.yml`** (forge-deploy `5df1180`). The service previously shipped without a `healthcheck:` stanza, so any downstream service declaring `depends_on: forge-storage condition: service_healthy` (notably `forge-ui`, and `forge-backup` once it was added) silently failed to start. The new healthcheck hits MinIO's own `/minio/health/live` endpoint at 10s intervals. `docker compose up -d` now brings the full stack up in one pass without needing to explicitly name dependent services.

### Clarified (not bugs — documentation drift)

- **`MockClock` gating is on `ASPNETCORE_ENVIRONMENT`, not `MOCK_INTEGRATIONS`.** Confirmed at `Program.cs:80` (`builder.Environment.IsDevelopment()`). `MOCK_INTEGRATIONS=false` will not switch the clock to `SystemClock`; set `ASPNETCORE_ENVIRONMENT=Production` (or any non-`Development` value) for that. TROUBLESHOOTING.md documents the env var to flip.
- **`OllamaAiService` is not a startup probe.** Service is `AddHttpClient<>` (transient), not instantiated at startup. The recurring `Ollama health check failed` stack trace in logs comes from `DocumentIndexJob` (a Hangfire recurring job) firing its first run on boot. The job catches the failure and no-ops, but the trace is logged at WRN. Cosmetic noise only; proper fix is to gate the job registration on the AI capability/profile so the first run doesn't fire when AI is disabled.
- **Health-check route is `/api/v1/health`.** Older notes say `/health`. Confirmed against the compose `healthcheck` stanza (`wget --spider http://localhost:8080/api/v1/health`). No `/health` route exists. DEPLOY.md corrected.
- **`setup.sh --cohost` binds UI to `127.0.0.1:4200`.** Older notes say `:80`. Cohost mode is the intended path for tunnel/proxy-fronted deploys; DEPLOY.md and the tunnel config reference use `4200`.

### Known issues (carried forward)

- **`forge-api` uses MinIO root credentials directly.** `docker-compose.yml:44-45` wires `Minio__AccessKey=${MINIO_ROOT_USER}` and `Minio__SecretKey=${MINIO_ROOT_PASSWORD}`. There is no separate scoped IAM user with bucket-only access. Acceptable on private-tunnel deployments; should be addressed before any deployment with broader network exposure. Fix is a forge-api change to consume a separate `MINIO_API_USER` / `MINIO_API_PASSWORD` plus a deploy-time `mc admin user add` step.
- **Preset documentation drift.** Earlier deploy notes referenced "PRESET-03 Plastics Manufacturing." `PresetCatalog.cs` lists PRESET-03 as **Distribution / Wholesale**. There is no Plastics-named preset. Applying PRESET-03 to a plastics manufacturer would disable BOM, Routing, WorkCenters, and all `MFG-*` capabilities — the opposite of intent. Operators must read the catalog at deploy time, not trust hand-off documents.
- **No `FORGE_PRESET` env var exists.** Preset application is admin-UI only via `POST /api/v1/presets/{id}/apply`. If reproducible/IaC-friendly preset application becomes a real requirement, it must be built; it cannot be configured around.
- **Rollback to an older release needs the database restored too.** (Corrected 2026-08-27 — this entry previously described EF Core auto-migrations, retired 2026-06-17.) Schema now comes from the forge-db reconcile, which runs *before* the app swap, so after a successful upgrade the database is at-or-ahead of the release you would return to; re-pinning an older image alone fails against it. `forge-deploy`'s own automatic rollback (health gate fails → previous tag re-pinned) is unaffected and needs none of this. Manual rollback = restore the pre-reconcile `pg_dump`, then re-pin `SERVER_IMAGE_TAG`, `UI_IMAGE_TAG` **and** `SCHEMA_IMAGE_TAG` together. Any release whose reconcile drops or rewrites anything must carry a "downgrade requires manual rollback from backup" note.
- **`SEED_USER_PASSWORD` is one-shot.** Changing the value in `.env` and re-deploying does not rotate the seeded admin's password if the Identity row already exists. Rotate via the admin UI, or wipe the DB and re-seed.

---

## Conventions for future entries

- One entry per merged change. Group related infra changes under a single `Changed` bullet only when they ship as a unit.
- `Fixed` entries that originated in app code (forge-api, forge-ui, forge-test) must reference the app version they ship in (image tag or git SHA).
- `Known issues` carries forward across releases until resolved. Move resolved items to a release's `Fixed` section in the same change that resolves them.
- Operational footguns surfaced during a deploy that we documented in TROUBLESHOOTING.md should also get an entry here under `Added` so they're discoverable in release notes.
