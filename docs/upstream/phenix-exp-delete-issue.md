# DRAFT (not posted): `phenix exp stop` marks the experiment stopped, and `exp delete` removes it, while its VMs keep running in minimega

Target: sceptre-phenix (confirmed against the build deployed here, branch 6cc94b23; code refs are local HEAD 3c6bb6a5).

## Symptom

After `phenix exp stop X` fails, `phenix exp list` shows X as stopped, `phenix exp delete X` succeeds, and the experiment
is gone from phenix. minimega still holds namespace X with its VMs RUNNING (seen once as VM ids 567-576 in a namespace
22 h after the experiment was deleted).

## Reproduction (phenix + minimega in docker, arm64; any topology works)

```bash
px() { phenix "$@"; }     # inside the phenix container
mm()  { mm "$@"; }        # inside the minimega container

px exp create delrepro -t <small-topology> && px exp start delrepro      # 2 VMs, running
# queue 80 more VMs into the same namespace and commit them, so minimega's scheduler is busy
mm namespace delrepro vm launch kvm 'extra[1-80]'
mm namespace delrepro vm launch &            # scheduleStat != Completed until every launch response is in
px exp stop delrepro                         # immediately
```

Observed:

```
ERR 1 error occurred:
	* killing experiment VMs: clearing minimega namespace: 1 error occurred:
	* scheduler still running for namespace
Error: Problem encountered while stopping the delrepro experiment (search error logs for <uuid>)   # exit 1
```

```
px exp list | grep delrepro      # STARTED column blank: phenix considers it stopped
mm namespace delrepro .columns state vm info     # 2 RUNNING, 80 BUILDING
px exp delete delrepro           # exit 0
px exp list | grep delrepro      # gone
mm namespace                     # delrepro still listed
mm namespace delrepro .columns state vm info     # still 2 RUNNING + 80 BUILDING (until `mm clear namespace delrepro` is retried by hand)
```

`mm clear namespace delrepro` works once the scheduler is done.

## Cause

1. `Namespace.Destroy` (minimega cmd/minimega/namespace.go:190-200) returns "scheduler still running for namespace" when
   any `scheduleStat` is not `SchedulerCompleted`; `DestroyNamespace` (namespace.go:988-1000) returns early and keeps the
   namespace, VMs untouched. (It also ignores the errors of `n.Kill(Wildcard)` and `n.FlushAll()`, lines 216-217.)
2. `experiment.Stop` (src/go/api/experiment/experiment.go:876-928) appends the `stopVMsAndDeleteSnapshots` error
   (-> `mm.ClearNamespace`, util/mm/minimega.go:76-87) to a multierror, but still runs `exp.Status.SetStartTime("")` and
   `store.Update(c)`. The experiment is persisted as not running although the VMs were not killed.
3. Nothing revisits minimega afterwards: `exp delete` (src/go/cmd/experiment.go:350-385) only calls `Stop` when
   `exp.Running()`, and `experiment.Delete` (experiment.go:1193-1240) never clears the namespace. A retried stop is
   rejected with "experiment isn't running" (experiment.go:894).

## Suggested fixes

- `experiment.Stop`: do not clear StartTime / persist "stopped" when `stopVMsAndDeleteSnapshots` fails (or add a distinct
  stop-failed status), so a retry is possible.
- `experiment.Delete` and `exp delete`: call `mm.ClearNamespace` (ignore "unknown namespace") or refuse to delete while
  the namespace still has VMs.
- `ClearNamespace`: verify afterwards that the namespace is gone.
- minimega: `Namespace.Destroy` should wait for or cancel the scheduler instead of erroring, and propagate Kill/FlushAll errors.

## Workaround here

`scripts/exp-down.sh` (range) and `experiment.verify_torn_down` (burger) check the namespace after stop/delete, retry
`clear namespace`, then `vm kill all` + `vm flush`, and fail loudly if VMs remain.
