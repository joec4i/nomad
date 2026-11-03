#!/usr/bin/env bash
# Reproduction: canary-drain-partial-plan. A node-drain migration whose replacement is
# not placed on the same eval still commits the stop on the draining node. With an
# unpromoted canary the follow-up reconcile places nothing, so the migrated alloc is
# never replaced. Two ways to get there, run as separate cases:
#
#   plan-reject  the placement is rejected at plan-apply time ("plan for node
#                rejected"); the refreshed reconcile places 0 and no blocked eval is
#                created.
#   sched-fail   no node fits at scheduling time; the stop is kept (it is not popped
#                for a migration) and a blocked eval is created. The stop itself frees
#                capacity, which unblocks that eval within ~150 ms, and the re-run
#                places 0.
#
# Expects docker-compose.canary-drain-partial-plan.yml; `up` and `all` start it.
#
#   scripts/canary-drain-partial-plan.sh all
#   scripts/canary-drain-partial-plan.sh up | down | clean
#   scripts/canary-drain-partial-plan.sh bug              plan-reject, pending canary
#   scripts/canary-drain-partial-plan.sh nocanary         plan-reject, control without a pending canary
#   scripts/canary-drain-partial-plan.sh clean-migration  control: pending canary, no rejection
#   scripts/canary-drain-partial-plan.sh sched-bug        sched-fail, pending canary
#   scripts/canary-drain-partial-plan.sh sched-nocanary   sched-fail, control without a pending canary
#
# How the plan-apply rejection is made (a natural race, no Nomad changes):
#   - 3 clients advertise 1000 MB. Ballast jobs leave the migration target T with
#     exactly one 300 MB slot free, and the other node U with two.
#   - The eval broker is paused, the node is drained (the drainer marks the alloc and
#     creates the evals), a rival job (priority 70, one 300 MB alloc, any node) is
#     registered, and the broker is resumed. The evals are then dequeued by different
#     scheduler workers at the same moment, both snapshots show T's free slot, and the
#     plan applier lets the rival's plan win it. The migration plan is then rejected
#     on T and its stop on the draining node still commits. The script retries (fresh
#     state each time) until that happens, at most CDPP_MAX_ATTEMPTS times.
#   - CDPP_ALIGN=none skips the pause: rival jobs are registered through the API for
#     3s around the drain, with nothing aligning them to the drain eval.
#
# Environment: CDPP_ALIGN=pause|none, CDPP_MAX_ATTEMPTS (12), CDPP_RIVALS (1; keep it
# below the number of active scheduler workers, 5 here), CDPP_KEEP_UP=1 (do not tear
# down after `all`), CDPP_OUT (log directory, default ./out), CDPP_NOMAD_IMAGE
# (default hashicorp/nomad:2.1.1), CDPP_PROJECT (compose project, canarydrain),
# CDPP_NOMAD_PORT (host port of the API, 34646).
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=${CDPP_PROJECT:-canarydrain}
IMAGE=${CDPP_NOMAD_IMAGE:-hashicorp/nomad:2.1.1}
export CDPP_NOMAD_IMAGE=$IMAGE
NOMAD_PORT=${CDPP_NOMAD_PORT:-34646}
API=http://127.0.0.1:$NOMAD_PORT
ALIGN=${CDPP_ALIGN:-pause}
MAX_ATTEMPTS=${CDPP_MAX_ATTEMPTS:-12}
RIVALS=${CDPP_RIVALS:-1}
OUT=${CDPP_OUT:-out}
JOB=canary-drain
SLOT=300 # MB, the size of one canary-drain alloc
FILLER=jobs/canary-drain-partial-plan-filler.nomad.hcl
SERVERS="nomad-server nomad-server2 nomad-server3"

compose() { docker compose -p "$PROJECT" -f docker-compose.canary-drain-partial-plan.yml "$@"; }
nomad() { compose exec -T nomad-server nomad "$@"; }
get() { curl -sf "$API$1"; }
# jq_ '<python expr over d>' reads JSON on stdin.
jq_() { python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
indent() { sed 's/^/    /'; }
# nomad prints a UI hint on stderr; keep a command's output only on failure.
quiet() { local out; out=$("$@" 2>&1) || { echo "$out" >&2; return 1; }; }

mkdir -p "$OUT"

# ---------------------------------------------------------------- cluster

up() {
  say "starting the lab (project $PROJECT, API $API)"
  compose up -d >/dev/null 2>&1
  wait_nodes
  note "$(nomad version | head -1); $(get /v1/nodes | jq_ 'len(d)') clients ready; servers: $(nomad server members 2>/dev/null | awk 'NR>1 && NF>6 {printf "%s(%s) ", $1, ($5=="true"?"leader":"follower")}')"
  note "server log_level DEBUG; image $IMAGE"
}

down() {
  say "tearing down"
  compose down -v 2>&1 | indent
}

node_ids() { get /v1/nodes | jq_ '" ".join(n["ID"] for n in d)'; }

wait_nodes() {
  local n
  for _ in $(seq 1 90); do
    n=$(get /v1/nodes 2>/dev/null | jq_ 'sum(1 for n in d if n["Status"] == "ready" and n["SchedulingEligibility"] == "eligible" and not n["Drain"])' 2>/dev/null || echo 0)
    [ "$n" = 3 ] && return
    sleep 2
  done
  echo "!! need 3 ready, eligible, non-draining nodes (have ${n:-0})" >&2
  return 1
}

# Back to an empty cluster: no jobs, nodes eligible, broker running.
clean() {
  local j id n
  nomad operator scheduler set-config -pause-eval-broker=false >/dev/null
  for j in $(get /v1/jobs | jq_ '" ".join(j["ID"] for j in d)'); do
    nomad job stop -purge -detach "$j" >/dev/null 2>&1
  done
  for id in $(node_ids); do
    nomad node drain -disable -yes "$id" >/dev/null 2>&1 || true
    nomad node eligibility -enable "$id" >/dev/null
  done
  for _ in $(seq 1 60); do
    n=$(get /v1/allocations | jq_ 'sum(1 for a in d if a["DesiredStatus"] == "run" and a["ClientStatus"] in ("pending", "running"))')
    [ "$n" = 0 ] && break
    sleep 1
  done
  nomad system gc >/dev/null
  wait_nodes
}

# ---------------------------------------------------------------- jobs and waiting

run_job() { # marker
  quiet nomad job run -detach -var "marker=$1" - < jobs/canary-drain-partial-plan.nomad.hcl
}

filler() { # id priority [-var ...]
  local id=$1 prio=$2
  shift 2
  sed "s/__ID__/$id/; s/__PRIORITY__/$prio/" "$FILLER" | quiet nomad job run -detach "$@" -
}

# wait_until '<python expr over d>' <path> <what>; WAIT_TRIES x WAIT_STEP seconds
wait_until() {
  for _ in $(seq 1 "${WAIT_TRIES:-90}"); do
    [ "$(get "$2" 2>/dev/null | jq_ "$1" 2>/dev/null || true)" = True ] && return
    sleep "${WAIT_STEP:-2}"
  done
  echo "!! timed out waiting for $3" >&2
  return 1
}

wait_deploy() { wait_until "$1" "/v1/job/$JOB/deployment" "deployment: $1"; }
running() { get "/v1/job/$1/allocations" | jq_ 'sum(1 for a in d if a["DesiredStatus"] == "run" and a["ClientStatus"] == "running")'; }
wait_running() { wait_until "sum(1 for a in d if a['DesiredStatus'] == 'run' and a['ClientStatus'] == 'running') == $2" "/v1/job/$1/allocations" "$1 running x$2"; }
blocked_evals() { get "/v1/job/$JOB/evaluations" | jq_ 'sum(1 for e in d if e["Status"] == "blocked")'; }

# v0, then v1 which starts a canary deployment that waits for promotion.
setup_canary() {
  say "setup: $JOB v0 (count 2), then v1 -> canary placed, not promoted"
  run_job v0
  wait_deploy 'd["JobVersion"] == 0 and d["Status"] == "successful"'
  run_job v1
  wait_deploy 'd["JobVersion"] == 1 and d["Status"] == "running" and "requires manual promotion" in d["StatusDescription"]'
  # "requires manual promotion" shows up before the canary is healthy, and a promote
  # at that point fails with: Task group "app" has 0/1 healthy allocations.
  wait_deploy 'd["JobVersion"] == 1 and d["TaskGroups"]["app"]["HealthyAllocs"] >= 1'
  sleep 2
}

# Same, then promote and wait for the deployment to finish: no pending canary.
setup_nocanary() {
  say "setup: $JOB v0, v1 canary, then promote and finish the deployment (no pending canary)"
  setup_canary
  nomad deployment promote "$(get /v1/job/$JOB/deployment | jq_ 'd["ID"]')" >/dev/null
  wait_deploy 'd["JobVersion"] == 1 and d["Status"] == "successful"'
  wait_until "sum(1 for a in d if a['DesiredStatus'] == 'run' and a['ClientStatus'] in ('pending', 'running')) == 2" "/v1/job/$JOB/allocations" "2 live allocs"
  sleep 2
}

# Allocs of the job, one line each.
allocs() {
  get "/v1/job/$JOB/allocations?all=true" | python3 -I -c '
import json, sys
for a in sorted(json.load(sys.stdin), key=lambda a: a["CreateIndex"]):
    ds = a.get("DeploymentStatus") or {}
    print("%s  %-13s v%s  canary=%-5s desired=%-5s client=%-8s %s" % (
        a["ID"][:8], a["NodeName"], a["JobVersion"], ds.get("Canary", False), a["DesiredStatus"], a["ClientStatus"], a.get("DesiredDescription") or ""))
'
}

# Live allocs by version: "v0 x1, v1 x1 (canary)".
live_summary() {
  get "/v1/job/$JOB/allocations" | python3 -I -c '
import json, sys
live = [a for a in json.load(sys.stdin) if a["DesiredStatus"] == "run" and a["ClientStatus"] in ("pending", "running")]
canary = sum(1 for a in live if (a.get("DeploymentStatus") or {}).get("Canary"))
old = sum(1 for a in live if a["JobVersion"] == 0)
print("%d live (%d of v0, %d of v1, %d of them canary); count is 2" % (len(live), old, len(live) - old, canary))
'
}

job_status() {
  nomad job status "$JOB" 2>/dev/null | awk '/^Summary/{p=1} /^Allocations/{p=0} p && NF' | indent
}

# ---------------------------------------------------------------- capacity layout

# Picks D (node to drain: hosts an old, non-canary alloc when $1 = canary), T (the
# migration target) and U (the other node), and the ballast that leaves T with $2
# free slots and U with $3. Prints KEY=VALUE lines.
layout() { # canary|nocanary t_slots u_slots
  python3 -I - "$API" "$JOB" "$SLOT" "$1" "$2" "$3" <<'EOF'
import json, sys, urllib.request
api, job, slot, mode, t_slots, u_slots = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
g = lambda p: json.load(urllib.request.urlopen(api + p))
nodes = g("/v1/nodes")
total = g("/v1/node/" + nodes[0]["ID"])["NodeResources"]["Memory"]["MemoryMB"]
used, mine = {}, {}
for n in nodes:
    live = [a for a in g("/v1/node/%s/allocations" % n["ID"]) if a["DesiredStatus"] == "run" and a["ClientStatus"] in ("pending", "running")]
    used[n["Name"]] = sum(t["Memory"]["MemoryMB"] for a in live for t in a["AllocatedResources"]["Tasks"].values())
    mine[n["Name"]] = [a for a in live if a["JobID"] == job]
ids = {n["Name"]: n["ID"] for n in nodes}
cands = []
for name, allocs in mine.items():
    for a in allocs:
        canary = (a.get("DeploymentStatus") or {}).get("Canary", False)
        if mode == "canary" and (canary or a["Job"]["Version"] != 0):
            continue
        cands.append((len(allocs), name, a["ID"]))
cands.sort()
_, D, old = cands[0]
others = sorted((len(mine[n]), n) for n in mine if n != D)
T, U = others[0][1], others[1][1]
print("D_NAME=%s" % D)
print("D_ID=%s" % ids[D])
print("OLD_ALLOC=%s" % old)
print("T_NAME=%s" % T)
print("U_NAME=%s" % U)
print("T_BALLAST=%d" % (total - used[T] - t_slots * slot))
print("U_BALLAST=%d" % (total - used[U] - u_slots * slot))
EOF
}

free_mem() { # node name
  python3 -I - "$API" "$1" <<'EOF'
import json, sys, urllib.request
api, name = sys.argv[1], sys.argv[2]
g = lambda p: json.load(urllib.request.urlopen(api + p))
n = next(n for n in g("/v1/nodes") if n["Name"] == name)
total = g("/v1/node/" + n["ID"])["NodeResources"]["Memory"]["MemoryMB"]
live = [a for a in g("/v1/node/%s/allocations" % n["ID"]) if a["DesiredStatus"] == "run" and a["ClientStatus"] in ("pending", "running")]
print(total - sum(t["Memory"]["MemoryMB"] for a in live for t in a["AllocatedResources"]["Tasks"].values()))
EOF
}

ballast() { # t_slots u_slots
  say "capacity: drain $D_NAME (hosts old alloc ${OLD_ALLOC:0:8}); migration target T=$T_NAME keeps $1 free slot(s), U=$U_NAME keeps $2"
  if [ "$T_BALLAST" -ge 10 ]; then filler ballast-t 50 -var "node=$T_NAME" -var "memory=$T_BALLAST"; fi
  if [ "$U_BALLAST" -ge 10 ]; then filler ballast-u 50 -var "node=$U_NAME" -var "memory=$U_BALLAST"; fi
  if [ "$T_BALLAST" -ge 10 ]; then wait_running ballast-t 1; fi
  if [ "$U_BALLAST" -ge 10 ]; then wait_running ballast-u 1; fi
  note "free memory: $T_NAME $(free_mem "$T_NAME") MB, $U_NAME $(free_mem "$U_NAME") MB (one alloc needs $SLOT MB)"
}

# ---------------------------------------------------------------- the drain and the race

# Drain D. $1 = yes: race rival jobs against the drain eval. Sets SINCE and BASE.
drain() {
  local i
  SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  BASE=$(get "/v1/job/$JOB/evaluations" | jq_ 'max([e["ModifyIndex"] for e in d] or [0])')
  if [ "$1" = no ]; then
    nomad node drain -enable -yes -detach "$D_ID" >/dev/null
    return
  fi
  case "$ALIGN" in
    pause)
      nomad operator scheduler set-config -pause-eval-broker=true >/dev/null
      nomad node drain -enable -yes -detach "$D_ID" >/dev/null
      # The drainer flags the alloc and creates its evals in one raft write; the
      # paused broker holds them until it is resumed.
      WAIT_STEP=0.2 WAIT_TRIES=100 wait_until "d['DesiredTransition'].get('Migrate') is True" "/v1/allocation/$OLD_ALLOC" "the drainer to flag the alloc"
      WAIT_STEP=0.2 WAIT_TRIES=100 wait_until "any(e['Status'] == 'pending' and e['CreateIndex'] > $BASE for e in d)" "/v1/job/$JOB/evaluations" "the drain eval"
      for i in $(seq 1 "$RIVALS"); do filler "rival-$i" 70 -var "memory=$SLOT"; done
      nomad operator scheduler set-config -pause-eval-broker=false >/dev/null
      ;;
    none)
      python3 -I - "$API" "$SLOT" <<'EOF' &
import json, sys, time, urllib.request
api, slot = sys.argv[1], int(sys.argv[2])
# Register rival jobs through the API in a tight loop for 3s, nothing aligned.
end, n = time.time() + 3, 0
while time.time() < end and n < 400:
    n += 1
    job = {"ID": "rival-%d" % n, "Name": "rival-%d" % n, "Type": "service", "Priority": 70, "Datacenters": ["dc1"],
           "TaskGroups": [{"Name": "filler", "Count": 1, "Tasks": [{"Name": "sleep", "Driver": "raw_exec",
             "Config": {"command": "/bin/sleep", "args": ["100000"]}, "Resources": {"CPU": 50, "MemoryMB": slot}}]}]}
    req = urllib.request.Request(api + "/v1/jobs", data=json.dumps({"Job": job}).encode(), method="PUT")
    try:
        urllib.request.urlopen(req).read()
    except Exception:
        pass
EOF
      nomad node drain -enable -yes -detach "$D_ID" >/dev/null
      wait
      ;;
  esac
}

# Wait until every eval of the job created since BASE has left pending/blocked-processing
# (blocked evals stay blocked), then settle.
settle() {
  wait_until "all(e['Status'] in ('complete', 'failed', 'canceled', 'blocked') for e in d if e['ModifyIndex'] > $BASE) and any(e['Status'] == 'complete' and e['CreateIndex'] > $BASE for e in d)" "/v1/job/$JOB/evaluations" "the evals of the drain to finish"
  sleep 4
}

job_evals() { get "/v1/job/$JOB/evaluations" | jq_ '" ".join(e["ID"] for e in d if e["CreateIndex"] > '"$BASE"')'; }

# Merged, time-ordered server logs (all 3 servers) since $1 (default SINCE).
server_log() {
  local s
  for s in $SERVERS; do
    # a server with nothing to say makes grep exit 1, which must not fail the pipeline
    { docker logs --since "${1:-$SINCE}" "$(compose ps -q "$s")" 2>&1 | grep -E '^ *[0-9]{4}-' || true; } \
      | sed -E "s/^ *([0-9T:.Z-]+) /\1 [${s#nomad-}] /"
  done | sort -s -k1,1
}

# Did a plan of one of the job's evals get a node rejected? Prints yes|no.
rejected() {
  local e log
  log=$(server_log | grep -F "plan for node rejected" || true)
  for e in $(job_evals); do
    if grep -qF "eval_id=$e" <<<"$log"; then echo yes; return; fi
  done
  echo no
}

# Did the scheduler fail to place at scheduling time and create a blocked eval for the job?
blocked_created() {
  local log
  log=$(server_log | grep -F "blocked eval created" | grep -F "job_id=$JOB" || true)
  if [ -n "$log" ]; then echo yes; else echo no; fi
}

# Scheduler, plan and worker lines of the job's evals, trimmed.
eval_log() { # [since]
  local e log
  log=$(server_log "${1:-$SINCE}")
  {
    for e in $(job_evals); do
      grep -F "$e" <<<"$log" | grep -E "dequeued|reconciled|plan for node rejected|refresh forced|blocked eval|failed to place|setting eval status|plan didn" || true
    done
  } | sort -s -k1,1 | awk '!seen[$0]++' \
    | sed -E 's/plan for node rejected, refer to [^ ]* for more information/plan for node rejected/; s/ worker_id=[0-9a-f-]+//; s/ namespace=default//; s/ total_destructive=0 total_inplace=0//; s/ total_disconnect=0 total_reconnect=0//; s/ node_id=""//; s/ type=service//' \
    | sed -E 's/(app_ignore=[0-9]+ app_place=[0-9]+) app_destructive=0 app_inplace=0 (app_stop=[0-9]+ app_migrate=[0-9]+ app_canary=[0-9]+) .*/\1 \2 .../' \
    | cut -c1-330
}

# ---------------------------------------------------------------- evidence

# What the rival jobs' evals did and where their allocs went (they raced for the free slot).
rival_evidence() {
  local r log
  r=$(get /v1/jobs | jq_ '" ".join(j["ID"] for j in d if j["ID"].startswith("rival-"))')
  [ -n "$r" ] || return 0
  note "-- rival job(s): $r"
  log=$(server_log)
  for e in $(for j in $r; do get "/v1/job/$j/evaluations" | jq_ '" ".join(e["ID"] for e in d)'; done); do
    grep -F "$e" <<<"$log" | grep -E "dequeued|reconciled|setting eval status" | sed -E 's/ worker_id=[0-9a-f-]+//; s/ namespace=default//; s/ type=service//; s/ node_id=""//; s/ total_destructive=0 total_inplace=0 total_disconnect=0 total_reconnect=0//' | cut -c1-260 | indent || true
  done
  for j in $r; do
    get "/v1/job/$j/allocations" | jq_ '"; ".join("%s: alloc %s on %s, client status %s" % (a["JobID"], a["ID"][:8], a["NodeName"], a["ClientStatus"]) for a in d)' | indent
  done
}

evidence() { # label
  say "evidence: $1"
  note "-- server log (DEBUG, 3 servers merged) for the job's evals"
  eval_log | indent
  rival_evidence
  note "-- nomad eval list -job $JOB"
  nomad eval list -job "$JOB" 2>/dev/null | grep -v '^$\|^==>' | indent
  note "-- blocked evals for $JOB: $(blocked_evals)"
  note "-- allocs"
  allocs | indent
  note "-- nomad alloc status ${OLD_ALLOC:0:8} (the migrated alloc)"
  nomad alloc status "$OLD_ALLOC" 2>/dev/null | sed -n 1,12p | indent
  note "-- nomad job status $JOB"
  job_status
  note "-- $(live_summary)"
}

cleanup_competition() {
  local i
  nomad job stop -purge -detach ballast-t >/dev/null 2>&1 || true
  nomad job stop -purge -detach ballast-u >/dev/null 2>&1 || true
  for i in $(get /v1/jobs | jq_ '" ".join(j["ID"] for j in d if j["ID"].startswith("rival-"))'); do
    nomad job stop -purge -detach "$i" >/dev/null 2>&1 || true
  done
}

# One scenario. $1 canary|nocanary, $2 plan-reject|sched-fail|clean
scenario() {
  local mode=$1 kind=$2 attempt hit=no t_slots=1 u_slots=2 tag max=$MAX_ATTEMPTS
  tag="$mode-$kind"
  if [ "$kind" = sched-fail ]; then t_slots=0 u_slots=0; fi
  if [ "$kind" != plan-reject ]; then max=1; fi
  for attempt in $(seq 1 "$max"); do
    say "[$tag] attempt $attempt/$max (pending canary: $mode, align=$ALIGN)"
    clean
    if [ "$mode" = canary ]; then setup_canary; else setup_nocanary; fi
    eval "$(layout "$mode" "$t_slots" "$u_slots")"
    ballast "$t_slots" "$u_slots"
    case "$kind" in
      plan-reject) drain yes ;;
      *) drain no ;;
    esac
    settle
    case "$kind" in
      plan-reject) hit=$(rejected); note "plan for node rejected for one of the job's evals: $hit" ;;
      sched-fail) hit=$(blocked_created); note "scheduler created a blocked eval at scheduling time: $hit" ;;
      clean) hit=yes; note "plan for node rejected: $(rejected) (expected no)" ;;
    esac
    if [ "$hit" = yes ]; then break; fi
  done
  server_log > "$OUT/server-$tag.log"
  if [ "$hit" != yes ]; then
    evidence "[$tag] NOT reproduced in $max attempts"
    echo "!! [$tag] no hit in $max attempts" >&2
    return 1
  fi
  evidence "[$tag] right after the drain, attempt $attempt"

  say "[$tag] freeing the capacity: ballast and rivals purged"
  SINCE2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cleanup_competition
  if [ "$kind" = sched-fail ]; then
    WAIT_TRIES=30 wait_until "not any(e['Status'] == 'blocked' for e in d) and all(e['Status'] in ('complete', 'failed', 'canceled') for e in d)" "/v1/job/$JOB/evaluations" "the blocked eval to run again" || true
  fi
  sleep 15
  note "-- server log since the capacity was freed"
  eval_log "$SINCE2" | indent
  note "-- blocked evals for $JOB: $(blocked_evals); running: $(running $JOB)"
  note "-- allocs"
  allocs | indent
  job_status
  note "-- $(live_summary)"
  server_log > "$OUT/server-$tag.log"

  if [ "$mode" = canary ] && [ "$kind" != clean ]; then
    say "[$tag] nomad deployment promote"
    nomad deployment promote "$(get /v1/job/$JOB/deployment | jq_ 'd["ID"]')" 2>&1 | grep -v '^$\|^==>' | indent
    wait_deploy 'd["Status"] == "successful"'
    wait_until "sum(1 for a in d if a['DesiredStatus'] == 'run' and a['ClientStatus'] in ('pending', 'running')) == 2" "/v1/job/$JOB/allocations" "2 live allocs"
    sleep 2
    note "-- allocs after the promotion"
    allocs | indent
    job_status
    note "-- $(live_summary)"
  fi
}

# ---------------------------------------------------------------- main

cmd=${1:-all}
case "$cmd" in
  up) up ;;
  down) down ;;
  clean) clean ;;
  bug) scenario canary plan-reject ;;
  nocanary) scenario nocanary plan-reject ;;
  clean-migration) scenario canary clean ;;
  sched-bug) scenario canary sched-fail ;;
  sched-nocanary) scenario nocanary sched-fail ;;
  all)
    up
    scenario canary sched-fail
    scenario nocanary sched-fail
    scenario canary plan-reject
    scenario nocanary plan-reject
    scenario canary clean
    clean
    if [ "${CDPP_KEEP_UP:-0}" != 1 ]; then down; fi
    ;;
  *) echo "usage: $0 all|up|down|clean|bug|nocanary|clean-migration|sched-bug|sched-nocanary" >&2; exit 1 ;;
esac
