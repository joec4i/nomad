# Nomad: a drain migration left unplaced while a canary awaits promotion is never retried

A self-contained docker-compose reproduction (3 Nomad servers and 3 clients, servers at DEBUG) of a scheduler bug. Related issue: [hashicorp/nomad#8671](https://github.com/hashicorp/nomad/issues/8671). Fix PR: [hashicorp/nomad#28730](https://github.com/hashicorp/nomad/pull/28730).

## The bug

A service job has `update { canary = N, auto_promote = false }` and its canary deployment is waiting for promotion. A node holding an old-version alloc is then drained. The scheduler plans a normal migration: stop the old alloc and place a replacement, in the same plan. The stop gets committed but the replacement does not, in one of two ways:

- **plan-reject.** The plan applier rejects the placement on the target node (`plan for node rejected`), and the plan is partially committed.
- **sched-fail.** The placement fails at scheduling time and the scheduler creates a blocked eval.

On the next pass the stopped alloc is server-terminal, and while canarying the reconciler only replaces lost or failed allocs. It computes `place=0`, the eval completes, and nothing retries. The slot stays empty until the deployment is promoted or failed. Without a pending canary, both paths self-heal.

Log lines of the drain eval on stock Nomad (DEBUG, eval ids elided):

```
# plan-reject
worker.service_sched: reconciled current state with desired state: total_place=1 total_stop=1 app_migrate=1 ...
nomad: plan for node rejected: node_id=... reason=memory eval_id=...
worker.service_sched: refresh forced: eval_id=...
worker.service_sched: reconciled current state with desired state: total_place=0 total_stop=0 app_ignore=2 app_place=0 app_migrate=0 ...
worker.service_sched: setting eval status: status=complete

# sched-fail
worker.service_sched: reconciled current state with desired state: total_place=1 total_stop=1 app_migrate=1 ...
worker.service_sched: failed to place all allocations, blocked eval created: eval_id=... blocked_eval_id=...
worker.service_sched: setting eval status: status=complete
worker: dequeued evaluation: eval_id=<blocked eval> triggered_by=queued-allocs
worker.service_sched: reconciled current state with desired state: total_place=0 total_stop=0 app_ignore=2 app_place=0 app_migrate=0 ...
worker.service_sched: setting eval status: status=complete
```

## Requirements

- Docker with compose v2, on linux/arm64 or linux/amd64, with about 2 CPUs and 2 GiB of memory for the Docker VM. The Nomad clients run privileged with the host cgroup namespace (cgroup v2).
- `python3` and `curl` on the host. No local `nomad` binary is needed; the CLI runs inside the server container.
- Nothing else is running as compose project `canarydrain` or on host port 34646. Both can be changed with `CDPP_PROJECT` and `CDPP_NOMAD_PORT`.

## Run

```bash
scripts/canary-drain-partial-plan.sh all          # the 5 scenarios below, then tear down
scripts/canary-drain-partial-plan.sh sched-bug    # a single scenario (see the table)
CDPP_KEEP_UP=1 scripts/canary-drain-partial-plan.sh all   # leave the cluster up afterwards
scripts/canary-drain-partial-plan.sh down         # tear down (also `up`, `clean`)
```

The image defaults to `hashicorp/nomad:2.1.1`; set `CDPP_NOMAD_IMAGE` to use another. Each scenario prints the server log lines of the job's evals, the allocs, and a live summary such as `3 live (2 of v0, 1 of v1, 1 of them canary); count is 2`. The merged server logs are kept in `out/`.

## Scenarios

`all` runs these in order and takes about 4 minutes. The two canary bug scenarios end by promoting the deployment, which fills the empty slot; the results below are taken before that.

| Scenario | Single-scenario command | Stock Nomad | Patched build |
|---|---|---|---|
| canary-sched-fail | `sched-bug` | Blocked eval created, re-run reconciles `place=0`, nothing retries. Ends with 1 old alloc plus the canary. | The eval stays blocked, then places an old-version alloc once capacity frees. Ends with 2 old allocs plus the canary. |
| nocanary-sched-fail | `sched-nocanary` | Control. The blocked eval places the replacement once capacity frees. Ends with 2 live allocs, all new version. | Same as stock. |
| canary-plan-reject | `bug` | `plan for node rejected`, the refresh pass reconciles `place=0`, no blocked eval. Ends with 1 old alloc plus the canary. | The refresh pass places an old-version alloc. Ends with 2 old allocs plus the canary. |
| nocanary-plan-reject | `nocanary` | Control. The refresh pass places the replacement. Ends with 2 live allocs, all new version. | Same as stock. |
| canary-clean | `clean-migration` | Control. Pending canary, no rejection or failure; the migration places normally. Ends with 2 old allocs plus the canary. | Same as stock. |

A note on reading the results: "running" counts the canary, so with `count = 2` the bug case still shows 2 running allocs. The signal is the old-version alloc count (`N of v0` in the live summary), not running against count.

## How the plan-reject case is lined up

Making the plan applier reject a placement needs two plans to compete for the same free slot. The cluster is arranged so the migration target has exactly one 300 MB slot free (ballast jobs fill the rest). The script then pauses the eval broker with the operator scheduler-config API (`nomad operator scheduler set-config -pause-eval-broker=true`), drains the node, registers a rival job (priority 70, one 300 MB alloc), and resumes the broker. Both evals are dequeued by different scheduler workers at the same moment, both snapshots show the free slot, and the plan applier lets the rival win it. The migration's placement is rejected and its stop on the drained node still commits.

The pause is an alignment aid only. It makes a race that is otherwise a matter of timing happen on demand, and there are no Nomad code changes. If an attempt does not hit it, the script retries from a clean cluster, up to `CDPP_MAX_ATTEMPTS` (default 12). `CDPP_ALIGN=none` skips the pause and registers rival jobs through the API for 3 seconds around the drain with nothing lining them up. There are three servers because a leader pauses 3/4 of its scheduler workers, so the followers' workers are what let evals of different jobs run in parallel.

## Testing a patched build

`scripts/build-patched-image.sh` compiles Nomad from a source checkout for the Docker server's architecture (needs Go), then builds an image `FROM hashicorp/nomad:2.1.1` with `/bin/nomad` replaced, tagged `nomad-patched:local`. To try the fix PR:

```bash
git clone --depth 1 -b b-canary-orphaned-migration https://github.com/joec4i/nomad nomad-fix
scripts/build-patched-image.sh ./nomad-fix
CDPP_NOMAD_IMAGE=nomad-patched:local scripts/canary-drain-partial-plan.sh all
```

An optional second argument sets the base image version and a third sets the image tag.

## Layout

```
docker-compose.canary-drain-partial-plan.yml    3 servers, 3 clients, project "canarydrain"
conf/canary-drain-partial-plan/                 Nomad agent configs
jobs/canary-drain-partial-plan.nomad.hcl        the job under test (canary = 1, auto_promote = false)
jobs/canary-drain-partial-plan-filler.nomad.hcl template for the ballast and rival jobs
scripts/canary-drain-partial-plan.sh            the scenarios
scripts/build-patched-image.sh                  build an image from a Nomad source checkout
```
