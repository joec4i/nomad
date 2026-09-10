// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: BUSL-1.1

package scheduler

import (
	"fmt"
	"testing"
	"time"

	"github.com/hashicorp/nomad/ci"
	"github.com/hashicorp/nomad/helper/testlog"
	"github.com/hashicorp/nomad/helper/uuid"
	"github.com/hashicorp/nomad/nomad/mock"
	"github.com/hashicorp/nomad/nomad/structs"
	"github.com/shoenig/test/must"
)

// canaryBoundFixture builds a job whose deployment is unpromoted and whose
// PlacedCanaries list has accumulated extra live canary generations.
type canaryBoundFixture struct {
	job            *structs.Job
	tg             string
	allocs         []*structs.Allocation
	deployment     *structs.Deployment
	canaryAllocIDs []string
}

func newCanaryBoundFixture(t *testing.T, count, canary, surplus int, reuseNames bool) *canaryBoundFixture {
	t.Helper()

	job := mock.Job()
	job.TaskGroups[0].Count = count
	job.TaskGroups[0].Update = &structs.UpdateStrategy{
		Canary:          canary,
		MaxParallel:     5,
		HealthCheck:     structs.UpdateStrategyHealthCheck_Checks,
		MinHealthyTime:  10 * time.Second,
		HealthyDeadline: 10 * time.Minute,
	}
	tg := job.TaskGroups[0].Name

	createIndex := uint64(100)
	newAlloc := func(idx uint) *structs.Allocation {
		createIndex++
		a := mock.Alloc()
		a.Job = job
		a.JobID = job.ID
		a.NodeID = uuid.Generate()
		a.TaskGroup = tg
		a.Name = structs.AllocName(job.ID, tg, idx)
		a.ClientStatus = structs.AllocClientStatusRunning
		a.DesiredStatus = structs.AllocDesiredStatusRun
		a.CreateIndex = createIndex
		return a
	}

	f := &canaryBoundFixture{job: job, tg: tg}

	for i := 0; i < count; i++ {
		f.allocs = append(f.allocs, newAlloc(uint(i)))
	}

	// Accumulated canary generations. Either all reusing one name (the
	// production shape, where the duplicate-index path kept handing back
	// index 0) or spread across distinct names.
	for i := 0; i < surplus+canary; i++ {
		idx := uint(0)
		if !reuseNames {
			idx = uint(count + i)
		}
		a := newAlloc(idx)
		a.DeploymentStatus = &structs.AllocDeploymentStatus{Canary: true}
		f.allocs = append(f.allocs, a)
		f.canaryAllocIDs = append(f.canaryAllocIDs, a.ID)
	}

	d := structs.NewDeployment(job, 50, time.Now().UnixNano())
	d.Status = structs.DeploymentStatusRunning
	d.TaskGroups[tg] = &structs.DeploymentState{
		Promoted:        false,
		DesiredCanaries: canary,
		DesiredTotal:    count,
		PlacedAllocs:    len(f.canaryAllocIDs),
		PlacedCanaries:  f.canaryAllocIDs,
	}
	f.deployment = d

	return f
}

func (f *canaryBoundFixture) compute(t *testing.T) *reconcileResults {
	t.Helper()
	return NewAllocReconciler(testlog.HCLogger(t), allocUpdateFnIgnore, false,
		f.job.ID, f.job, f.deployment, f.allocs, nil, "", 50, true).Compute()
}

// An unpromoted deployment must not retain more than Update.Canary live
// canaries. Before the fix, computeStop exempted every allocation named in the
// cumulative PlacedCanaries list, so a group of 21 could hold 36 running
// allocations forever and report (stop 0).
func TestReconciler_UnpromotedCanary_BoundsLiveCanaries(t *testing.T) {
	ci.Parallel(t)

	const (
		count  = 21
		canary = 1
	)

	for _, reuseNames := range []bool{true, false} {
		for _, surplus := range []int{0, 1, 5, 15} {
			name := fmt.Sprintf("reuse_names=%v/surplus=%d", reuseNames, surplus)
			t.Run(name, func(t *testing.T) {
				f := newCanaryBoundFixture(t, count, canary, surplus, reuseNames)
				r := f.compute(t)

				// Exactly the overflow generations are stopped, and nothing
				// is placed.
				must.Zero(t, len(r.place))
				must.Eq(t, surplus, len(r.stop))
				must.Eq(t, uint64(surplus), r.desiredTGUpdates[f.tg].Stop)

				// Only canaries are stopped, never the stable allocations.
				stopped := map[string]bool{}
				for _, s := range r.stop {
					must.True(t, s.alloc.DeploymentStatus.IsCanary(),
						must.Sprintf("stopped a non-canary alloc %s (%s)",
							s.alloc.ID, s.alloc.Name))
					stopped[s.alloc.ID] = true
				}

				// The retained canaries are the newest ones.
				retained := 0
				for _, id := range f.canaryAllocIDs {
					if !stopped[id] {
						retained++
					}
				}
				must.Eq(t, canary, retained)

				// Applying the plan leaves count + canary allocations.
				must.Eq(t, count+canary, len(f.allocs)-len(r.stop))
			})
		}
	}
}

// Repeated evaluations of an unpromoted deployment must converge: the surplus
// is stopped once and nothing new is placed afterwards.
func TestReconciler_UnpromotedCanary_ConvergesAcrossEvals(t *testing.T) {
	ci.Parallel(t)

	const (
		count   = 21
		canary  = 1
		surplus = 15
	)

	f := newCanaryBoundFixture(t, count, canary, surplus, true)

	r := f.compute(t)
	must.Eq(t, surplus, len(r.stop))

	// Apply the plan: drop the stopped allocations and prune them from
	// PlacedCanaries the way a subsequent state-store write would not (the
	// list is cumulative), to prove the bound holds even with a stale list.
	stopped := map[string]bool{}
	for _, s := range r.stop {
		stopped[s.alloc.ID] = true
	}
	remaining := make([]*structs.Allocation, 0, len(f.allocs))
	for _, a := range f.allocs {
		if !stopped[a.ID] {
			remaining = append(remaining, a)
		}
	}
	f.allocs = remaining

	for i := range 5 {
		r = f.compute(t)
		must.Zero(t, len(r.place), must.Sprintf("eval %d placed allocations", i))
		must.Zero(t, len(r.stop), must.Sprintf("eval %d stopped allocations", i))
		must.Eq(t, count+canary, len(f.allocs))
	}
}

// A promoted deployment keeps the pre-existing behaviour: the canary exemption
// does not apply and same-named old allocations are stopped instead.
func TestReconciler_PromotedCanary_ExemptionDoesNotApply(t *testing.T) {
	ci.Parallel(t)

	f := newCanaryBoundFixture(t, 21, 1, 5, true)
	f.deployment.TaskGroups[f.tg].Promoted = true

	// 21 stable + 6 canaries = 27 live, count 21, so the 6 surplus are
	// stopped by ordinary count reconciliation.
	r := f.compute(t)
	must.Zero(t, len(r.place))
	must.Eq(t, 6, len(r.stop))
	must.Eq(t, 21, len(f.allocs)-len(r.stop))
}

func TestLimitLiveCanaries(t *testing.T) {
	ci.Parallel(t)

	alloc := func(id, name string, createIndex uint64, terminal bool) *structs.Allocation {
		a := &structs.Allocation{
			ID:            id,
			Name:          name,
			CreateIndex:   createIndex,
			DesiredStatus: structs.AllocDesiredStatusRun,
			ClientStatus:  structs.AllocClientStatusRunning,
		}
		if terminal {
			a.DesiredStatus = structs.AllocDesiredStatusStop
		}
		return a
	}

	t.Run("keeps newest per name then caps on count", func(t *testing.T) {
		set := allocSet{
			"a1": alloc("a1", "job.tg[0]", 10, false),
			"a2": alloc("a2", "job.tg[0]", 20, false), // newest for [0]
			"b1": alloc("b1", "job.tg[1]", 5, false),  // only canary for [1]
		}

		retained, excess := limitLiveCanaries(set, 2)
		must.Eq(t, 2, len(retained))
		must.Eq(t, 1, len(excess))
		must.MapContainsKey(t, excess, "a1")

		retained, excess = limitLiveCanaries(set, 1)
		must.Eq(t, 1, len(retained))
		must.Eq(t, 2, len(excess))
		must.MapContainsKey(t, retained, "a2") // highest CreateIndex wins
	})

	t.Run("terminal canaries are retained not stopped", func(t *testing.T) {
		set := allocSet{
			"t1": alloc("t1", "job.tg[0]", 30, true),
			"a1": alloc("a1", "job.tg[0]", 10, false),
			"a2": alloc("a2", "job.tg[0]", 20, false),
		}

		retained, excess := limitLiveCanaries(set, 1)
		must.MapContainsKey(t, retained, "t1")
		must.MapContainsKey(t, retained, "a2")
		must.MapContainsKey(t, excess, "a1")
	})

	t.Run("pending and unknown canaries are never excess", func(t *testing.T) {
		pending := alloc("p1", "job.tg[0]", 5, false)
		pending.ClientStatus = structs.AllocClientStatusPending
		unknown := alloc("u1", "job.tg[0]", 6, false)
		unknown.ClientStatus = structs.AllocClientStatusUnknown

		set := allocSet{
			"p1": pending,
			"u1": unknown,
			"a1": alloc("a1", "job.tg[0]", 10, false),
		}

		// Only the one running canary competes, and it is within the limit,
		// so nothing is stopped even though three canaries share a name.
		retained, excess := limitLiveCanaries(set, 1)
		must.Eq(t, 3, len(retained))
		must.Eq(t, 0, len(excess))
	})

	t.Run("zero limit stops every live canary", func(t *testing.T) {
		set := allocSet{"a1": alloc("a1", "job.tg[0]", 10, false)}
		retained, excess := limitLiveCanaries(set, 0)
		must.Eq(t, 0, len(retained))
		must.Eq(t, 1, len(excess))
	})

	t.Run("deterministic across repeated runs", func(t *testing.T) {
		set := allocSet{
			"a1": alloc("a1", "job.tg[0]", 10, false),
			"a2": alloc("a2", "job.tg[0]", 10, false), // CreateIndex tie
			"a3": alloc("a3", "job.tg[0]", 10, false),
		}
		_, first := limitLiveCanaries(set, 1)
		for range 20 {
			_, again := limitLiveCanaries(set, 1)
			must.Eq(t, len(first), len(again))
			for id := range first {
				must.MapContainsKey(t, again, id)
			}
		}
	})
}
