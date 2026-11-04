# Nomad: a drain migration left unplaced while a canary awaits promotion is never retried

A self-contained docker-compose reproduction (3 Nomad servers and 3 clients, servers at DEBUG) of a scheduler bug. Related issue: [hashicorp/nomad#8671](https://github.com/hashicorp/nomad/issues/8671). Fix PR: [hashicorp/nomad#28730](https://github.com/hashicorp/nomad/pull/28730).

## The bug

A service job has `update { canary = N, auto_promote = false }` and its canary deployment is waiting for promotion. A node holding old-version allocs is then drained. The scheduler plans a normal migration: stop the old allocs and place replacements, in the same plan. The stops get committed but a replacement does not, in one of two ways:

- **plan-reject.** The plan applier rejects the placement on the target node (`plan for node rejected`), and the plan is partially committed.
- **sched-fail.** The placement fails at scheduling time and the scheduler creates a blocked eval.

On the next pass the stopped alloc is server-terminal, and while canarying the reconciler only replaces lost or failed allocs. It computes `place=0`, the eval completes, and nothing retries. The slot stays empty until the deployment is promoted or failed. Without a pending canary, both paths self-heal.

## The job

[`jobs/canary-drain-partial-plan.nomad.hcl`](jobs/canary-drain-partial-plan.nomad.hcl), registered as `v0` and then as `v1` (only the `MARKER` env differs) to start a canary deployment:

```hcl
job "canary-drain" {
  datacenters = ["dc1"]
  type        = "service"

  update {
    canary            = 1
    auto_promote      = false
    max_parallel      = 1
    auto_revert       = false
    health_check      = "task_states"
    min_healthy_time  = "3s"
    healthy_deadline  = "2m"
    progress_deadline = "10m"
  }

  migrate {
    max_parallel     = 1
    health_check     = "task_states"
    min_healthy_time = "3s"
    healthy_deadline = "2m"
  }

  group "app" {
    count = 5

    spread {
      attribute = "${node.unique.name}"
    }

    task "app" {
      driver = "raw_exec"

      config {
        command = "/bin/sleep"
        args    = ["100000"]
      }

      env {
        MARKER = "v1" # v0 for the first registration
      }

      resources {
        cpu    = 50
        memory = 100
      }
    }
  }
}
```

## Expected vs actual

Setup for both cases: `v0` with `count = 5` is running, `v1` is registered and its canary is healthy but not promoted (`Deployment is running but requires manual promotion`), so 5 old allocs plus 1 canary are running. Then `nomad-client1`, which hosts 2 old allocs, is drained.

**Expected:** each stopped old alloc gets a replacement, so 5 old allocs plus the canary are running, as they were before the drain.

**Actual:** at least one replacement never appears, and nothing retries it. The numbers below are from the real runs; `nomad job status canary-drain` is shown right after the drain settled.

### plan-reject (`scripts/canary-drain-partial-plan.sh bug`)

A rival job wins the one free slot on the migration target while the drain eval is being planned. The plan applier rejects that node's placement, and the plan is partly committed: both stops, and the one placement that landed on the other node. One old alloc is lost: 4 old allocs plus the canary are running instead of 5 plus the canary.

```
Summary
Task Group  Queued  Starting  Running  Failed  Complete  Lost  Unknown
app         0       0         5        0       2         0     0

Latest Deployment
ID          = 4d8cc954
Status      = running
Description = Deployment is running but requires manual promotion

Deployed
Task Group  Promoted  Desired  Canaries  Placed  Healthy  Unhealthy  Progress Deadline
app         false     5        1         1       1        0          2026-11-04T10:47:59Z

Allocations
ID        Node ID   Task Group  Version  Desired  Status    Created  Modified
a044cab7  ea0bb737  app         0        run      running   7s ago   3s ago       <- the one replacement that was placed
bf71efca  838634c0  app         1        run      running   17s ago  13s ago      <- canary
0e689625  ea0bb737  app         0        run      running   23s ago  20s ago
19827bd6  3384c019  app         0        stop     complete  23s ago  6s ago       <- drained
5ac0a6d0  838634c0  app         0        run      running   23s ago  20s ago
7e9043e3  ea0bb737  app         0        run      running   23s ago  20s ago
e9537bb2  3384c019  app         0        stop     complete  23s ago  6s ago       <- drained
```

Of the two drained allocs, only one has a replacement (`a044cab7`). The `Running 5` includes the canary, so it matches the group count and hides the missing alloc; count the old-version allocs instead.

Server log of the drain eval (`8e619c4f`):

```
[DEBUG] worker: dequeued evaluation: eval_id=8e619c4f job_id=canary-drain triggered_by=node-drain
[DEBUG] worker.service_sched: reconciled current state with desired state: eval_id=8e619c4f job_id=canary-drain total_place=2 total_stop=2 app_ignore=4 app_place=0 app_stop=0 app_migrate=2 app_canary=0 ...
[INFO]  nomad: plan for node rejected: node_id=838634c0 reason=memory eval_id=8e619c4f
[DEBUG] worker.service_sched: refresh forced: eval_id=8e619c4f job_id=canary-drain
[DEBUG] worker.service_sched: reconciled current state with desired state: eval_id=8e619c4f job_id=canary-drain total_place=0 total_stop=0 app_ignore=5 app_place=0 app_stop=0 app_migrate=0 app_canary=0 ...
[DEBUG] worker.service_sched: setting eval status: eval_id=8e619c4f job_id=canary-drain status=complete
```

Expected after the refresh: `total_place=1` for the rejected placement. Actual: `total_place=0`, and the eval completes with the slot empty.

### sched-fail (`scripts/canary-drain-partial-plan.sh sched-bug`)

The other two clients have no free memory, so the replacements cannot be placed. Both old allocs on the drained node are stopped, none is replaced, and the blocked eval does nothing: 3 old allocs plus the canary are running instead of 5 plus the canary.

```
Summary
Task Group  Queued  Starting  Running  Failed  Complete  Lost  Unknown
app         0       0         4        0       2         0     0

Latest Deployment
ID          = 1bd255db
Status      = running
Description = Deployment is running but requires manual promotion

Deployed
Task Group  Promoted  Desired  Canaries  Placed  Healthy  Unhealthy  Progress Deadline
app         false     5        1         1       1        0          2026-11-04T10:52:44Z

Allocations
ID        Node ID   Task Group  Version  Desired  Status    Created  Modified
cfca4746  838634c0  app         1        run      running   17s ago  13s ago      <- canary
0433e3f9  ea0bb737  app         0        run      running   23s ago  19s ago
3e2ddad8  3384c019  app         0        stop     complete  23s ago  7s ago       <- drained, not replaced
4e93128a  3384c019  app         0        stop     complete  23s ago  7s ago       <- drained, not replaced
967492e3  838634c0  app         0        run      running   23s ago  20s ago
d0bf92de  ea0bb737  app         0        run      running   23s ago  19s ago
```

Server log of the drain eval (`5c8c6450`) and the blocked eval it created (`bb5ed56f`):

```
[DEBUG] worker: dequeued evaluation: eval_id=5c8c6450 job_id=canary-drain triggered_by=node-drain
[DEBUG] worker.service_sched: reconciled current state with desired state: eval_id=5c8c6450 job_id=canary-drain total_place=2 total_stop=2 app_ignore=4 app_place=0 app_stop=0 app_migrate=2 app_canary=0 ...
[DEBUG] worker.service_sched: failed to place all allocations, blocked eval created: eval_id=5c8c6450 job_id=canary-drain blocked_eval_id=bb5ed56f
[DEBUG] worker.service_sched: setting eval status: eval_id=5c8c6450 job_id=canary-drain status=complete
[DEBUG] worker: dequeued evaluation: eval_id=bb5ed56f job_id=canary-drain triggered_by=queued-allocs
[DEBUG] worker.service_sched: reconciled current state with desired state: eval_id=bb5ed56f job_id=canary-drain total_place=0 total_stop=0 app_ignore=4 app_place=0 app_stop=0 app_migrate=0 app_canary=0 ...
[DEBUG] worker.service_sched: setting eval status: eval_id=bb5ed56f job_id=canary-drain status=complete
```

Expected on the second pass: `total_place=2` (or the eval stays blocked until capacity frees). Actual: `total_place=0`, and the eval completes.

**Neither case recovers by itself.** After the ballast and rival jobs are purged (capacity is free again) and the drained node is put back (`nomad node drain -disable`, `nomad node eligibility -enable`), the script waits 15 seconds: no eval runs for the job, there is no blocked eval, and the job status is unchanged (4 old allocs plus the canary after plan-reject, 3 after sched-fail). Only `nomad deployment promote` fills the empty slots, which is why this is easy to miss.

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

The image defaults to `hashicorp/nomad:2.1.1`; set `CDPP_NOMAD_IMAGE` to use another. Each scenario prints the server log lines of the job's evals, the allocs, and `nomad job status` output. The merged server logs are kept in `out/`.

## Manual reproduction (sched-fail)

The sched-fail case needs no race, so it can be done by hand against the compose cluster:

1. `docker compose up -d`, then `export NOMAD_ADDR=http://127.0.0.1:34646` (or run `nomad` inside the `nomad-server` container).
2. `nomad job run -var marker=v0 jobs/canary-drain-partial-plan.nomad.hcl`, and wait for the deployment to be `successful`.
3. `nomad job run -var marker=v1 jobs/canary-drain-partial-plan.nomad.hcl`. Wait until the canary is healthy and the deployment says `requires manual promotion`. Do not promote it.
4. In `nomad job status canary-drain`, pick a node to drain that has old (version 0) allocs and not the canary.
5. Fill the other two nodes completely: for each, register a job from `jobs/canary-drain-partial-plan-filler.nomad.hcl` (replace `__ID__` with a job id and `__PRIORITY__` with `50`) with `-var node=<name> -var memory=<MB>`, where `<MB>` is 1000 minus the memory already allocated on that node (100 per `canary-drain` alloc; see `nomad node status <node>`).
6. `nomad node drain -enable -yes -detach <node to drain>`.
7. `nomad job status canary-drain` shows the drained old allocs as `stop`/`complete` with no replacements, and the server log has `failed to place all allocations, blocked eval created`. The blocked eval has already re-run by then (the stops on the drained node freed capacity and unblocked it within ~100 ms) and reconciled `place=0`. Stop the filler jobs to free capacity on the other nodes: no eval is triggered, and nothing is placed until you run `nomad deployment promote`.

The plan-reject case needs two plans to compete for the same slot at the same moment; use the script for that (see below).

## Scenarios

`all` runs these in order and takes about 5 minutes. The two canary bug scenarios end by promoting the deployment, which fills the empty slots; the results below are taken before that.

| Scenario | Single-scenario command | Stock Nomad | Patched build |
|---|---|---|---|
| canary-plan-reject | `bug` | `plan for node rejected`, the refresh pass reconciles `place=0`, no blocked eval. Ends with 4 old allocs plus the canary. | The refresh pass places the missing old-version alloc. Ends with 5 old allocs plus the canary. |
| nocanary-plan-reject | `nocanary` | Control. The refresh pass places the replacement. Ends with 5 live allocs, all new version. | Same as stock. |
| canary-sched-fail | `sched-bug` | Blocked eval created, re-run reconciles `place=0`, nothing retries. Ends with 3 old allocs plus the canary. | The eval stays blocked, then places old-version allocs once capacity frees. Ends with 5 old allocs plus the canary. |
| nocanary-sched-fail | `sched-nocanary` | Control. The blocked eval places the replacements once capacity frees. Ends with 5 live allocs, all new version. | Same as stock. |
| canary-clean | `clean-migration` | Control. Pending canary, no rejection or failure; the migration places normally. Ends with 5 old allocs plus the canary. | Same as stock. |

A note on reading the results: "running" counts the canary, so the plan-reject bug case still shows 5 running allocs with `count = 5`. The signal is the old-version alloc count (`N of v0` in the live summary), not running against count.

## How the plan-reject case is lined up

Making the plan applier reject a placement needs two plans to compete for the same free slot. The cluster is arranged so the migration target has exactly one 100 MB slot free (ballast jobs fill the rest). The script then pauses the eval broker with the operator scheduler-config API (`nomad operator scheduler set-config -pause-eval-broker=true`), drains the node, registers a rival job (priority 70, one 100 MB alloc), and resumes the broker. Both evals are dequeued by different scheduler workers at the same moment, both snapshots show the free slot, and the plan applier lets the rival win it. The migration's placement on that node is rejected and its stops on the drained node still commit.

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
docker-compose.yml                              3 servers, 3 clients, project "canarydrain"
conf/canary-drain-partial-plan/                 Nomad agent configs
jobs/canary-drain-partial-plan.nomad.hcl        the job under test (canary = 1, auto_promote = false)
jobs/canary-drain-partial-plan-filler.nomad.hcl template for the ballast and rival jobs
scripts/canary-drain-partial-plan.sh            the scenarios
scripts/build-patched-image.sh                  build an image from a Nomad source checkout
```
