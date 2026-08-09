# Incident: nightly reconciliation pass dies inside the client, on a different account every time

## Reported by

A customer running a .NET service against RavenDB 7.2. The service performs a nightly
reconciliation pass over their account book.

## What the customer sees

The pass runs for anything between a few seconds and a few minutes and then falls over with
an exception raised from inside the client, on a batch of accounts that has nothing wrong
with it. Three of the reports they sent us, from three different nights:

```
System.ArgumentOutOfRangeException: Specified argument was out of the range of valid values.
(Parameter 'Property names offset flag should be either byte, short of int, instead of
 StartArray, PositionMask, PropertyIdSizeByte')
```

```
System.IO.InvalidDataException: Properties offset not valid
```

```
System.NullReferenceException: Object reference not set to an instance of an object.
   at Raven.Client.Documents.Session.Operations.LoadOperation.GetDocumentsFromResult(...)
```

On other nights nothing is thrown at all and the pass instead reads an account that
demonstrably exists as missing, or reads it with the wrong balance, and carries that value
into the settlement it writes. That silent variant is what worries them most.

Their observations, in their words:

- it only happens on the reconciliation path, which batches several lookups together using
  lazy operations;
- it only happens while aggressive caching is enabled;
- the account it dies on is different every time, and the account itself is fine - reading
  it again immediately afterwards returns the right document;
- one of the ids in each batch is a settlement record for tonight, which usually has not
  been written yet, so that lookup normally comes back empty;
- restarting the process makes it go away for a while;
- it got noticeably worse when they moved from one reconciliation thread to sixteen, and
  worse again when they capped the client cache to keep several jobs on one box;
- none of their own single-threaded tests can reproduce it, which is why the report sat
  unresolved for a month.

## Environment

- RavenDB 7.2, single node
- .NET 10
- client aggressive caching enabled, `AggressiveCacheMode.DoNotTrackChanges`
- `MaxHttpCacheSize` capped at 1 MB
- sixteen reconciliation workers, lazy batches of five requests
- one id in every batch is normally absent

## Reproducing on this stand

We rebuilt the customer's job here and it ships with the stand, under
`assessment/reconciliation-job/`. It is an ordinary console application; it is built against
the client in this tree, so a change you make to `Raven.Client` is picked up by the next run.

From the repository root:

```powershell
pwsh assessment/scripts/setup-check.ps1
```

Verifies the toolchain and builds the server and the job. Neither the full solution nor the
test suites are needed to start.

```powershell
pwsh assessment/scripts/start-server.ps1
```

Starts a RavenDB server on `http://127.0.0.1:8080` in the foreground. Leave it in its own
terminal. If you already run one, point the job at it with the `RECONCILIATION_URL`
environment variable instead.

```powershell
pwsh assessment/scripts/run-incident.ps1
```

Runs the pass and rewrites everything under `assessment/EVIDENCE/` from that run.

**This is not a deterministic reproduction, and you should not expect one.** The pass runs
until it hits an anomaly or until its time budget expires, whichever comes first:

- exit code 1 - it reproduced, and `EVIDENCE/` now describes that run;
- exit code 0 - this particular run stayed clean; run it again.

The budget defaults to five minutes and can be changed with `-Minutes`. Across the captures
in `EVIDENCE/run-history.txt` the pass has never survived a full budget, and usually gives
up in the first few seconds; but the failing account, the exception and the time to failure
are different every time.

Because the reproduction is not deterministic, how readily it shows up can depend on the
machine. **If ten consecutive five-minute runs come back clean, stop retrying** - that
indicates your hardware does not let the problem surface, not that the problem is absent.
Tell us and we will offer you an alternative.

The job drops and recreates its database on every run, so runs do not contaminate each
other.

## Evidence in this package

| File | What it is |
| --- | --- |
| `EVIDENCE/application.log` | Timeline the pass printed on the most recent capture, with per-step counters |
| `EVIDENCE/client-stack-traces.txt` | The exception that capture caught, as the client reported it |
| `EVIDENCE/runtime-and-counters.txt` | Machine and runtime the capture was taken on, plus the counters pulled out of the run |
| `EVIDENCE/run-history.txt` | One line per capture we have taken, oldest first - this is where the run-to-run variation is visible |
| `EVIDENCE/support-notes.md` | What each artifact does and does not establish |

## What we need

1. An explanation of the mechanism, in terms of the RavenDB code that actually runs on
   this path - not a restatement of the symptom.
2. A statement of which component owns the incorrect state and when it goes wrong.
3. An explanation of why the failure is intermittent, and of what decides whether a given
   run survives. Naming a general category is not an answer; we want the specific
   interaction, and what opens and closes the window in which it goes wrong.
4. A fix you would be comfortable shipping, with a short note on why the alternatives you
   considered are worse.
5. A regression test that fails before your change and passes after it, and that would
   keep failing if someone reintroduced the same class of mistake in a different shape.
   Say how confident you are that it fails reliably, and on what evidence.
6. An assessment of blast radius: which other RavenDB features can reach the same state,
   and what a customer would see there.

Write your findings the way you would send them to the customer.
