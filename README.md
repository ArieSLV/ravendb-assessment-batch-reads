# Cached batch reads — field investigation

A full RavenDB 7.2 source tree plus one customer incident to investigate.

A .NET service runs a nightly reconciliation pass over an account book. The pass dies inside the
RavenDB client, on a different account every time, and on some nights it does not throw at all — it
silently reads an account that exists as missing and carries that value into a settlement. It only
happens with aggressive caching on, only on the path that batches lookups with lazy operations, and
none of the customer's own single-threaded tests reproduce it.

Your job is to find out why, fix it, and prove the fix.

---

## Prerequisites

- **.NET 10 SDK and runtime**
- **PowerShell 7+** (`pwsh`)
- **Windows.** This is what we build and run the stand on, and the only platform we have verified.
  Nothing here is deliberately Windows-only, but we have not tried it anywhere else — if you want to
  work on another platform, tell us first.
- **A RavenDB license** — step 1 below
- ~2 GB free disk for build output

You do **not** need to build `RavenDB.sln` or run the test suites to start.

---

## Quick start

**1 — Get a license and drop it in.** The server will not start without one. A free developer license
is enough: request one at <https://ravendb.net/license/request/dev> and save the file you receive as
`license.json` in the root of this repository, next to `RavenDB.sln`.

That is the only place the scripts look. `setup-check.ps1` tells you if it is missing and
`start-server.ps1` refuses to start without it, so you will find out immediately rather than halfway
through. `license.json` is git-ignored — you will not commit yours by accident.

**2 — Read the incident.**

[`assessment/INCIDENT.md`](assessment/INCIDENT.md) is the ticket: what the customer sees, what they
already ruled out, the environment, and what we need back from you.

**3 — Preflight.** Checks your toolchain and the license, and builds the server and the job.

```powershell
pwsh assessment/scripts/setup-check.ps1
```

**4 — Start a server.** Leave this running in its own terminal. It listens on
`http://127.0.0.1:8080`, unsecured, no setup wizard.

```powershell
pwsh assessment/scripts/start-server.ps1
```

**5 — Run the pass.** In another terminal:

```powershell
pwsh assessment/scripts/run-incident.ps1
```

Exit code `1` means it reproduced and `assessment/EVIDENCE/` now describes that run. Exit code `0`
means the run produced no anomaly — what that tells you depends on whether you have changed anything
yet, and the run prints both readings.

---

## The reproduction is not deterministic

This is deliberate, and it matches how the problem behaves in production. The pass runs until it hits
an anomaly or until its time budget expires, whichever comes first. The failing account, the exception
and the time to failure are different every time.

```powershell
pwsh assessment/scripts/run-incident.ps1 -Minutes 10
```

The budget defaults to five minutes. Across our own captures the pass has never survived a full
budget and usually gives up in the first few seconds.

**If ten consecutive five-minute runs come back clean before you have changed anything, stop retrying
and tell us.** We will sort it out with you rather than have you burn an evening on it.

---

## What is in the package

| Path | What it is |
| --- | --- |
| [`assessment/INCIDENT.md`](assessment/INCIDENT.md) | The ticket, the environment, how to reproduce, and what we need from you |
| `assessment/EVIDENCE/application.log` | Timeline the pass printed on the most recent capture, with per-step counters |
| `assessment/EVIDENCE/client-stack-traces.txt` | The exception that capture caught, as the client reported it |
| `assessment/EVIDENCE/runtime-and-counters.txt` | Machine and runtime the capture was taken on, plus counters from the run |
| `assessment/EVIDENCE/run-history.txt` | One line per capture, oldest first — where the run-to-run variation is visible |
| `assessment/EVIDENCE/support-notes.md` | What each artifact does and does not establish |
| `assessment/reconciliation-job/` | The customer's job, rebuilt. A plain console application |
| `assessment/scripts/` | Preflight, server, and the reproduction pass |
| `src/`, `test/` | The RavenDB source tree, unmodified except for what the incident touches |

The job builds against `Raven.Client` **from this tree**, so a change you make to the client is picked
up by the next run. It drops and recreates its database on every run, so runs do not contaminate each
other.

---

## What we need from you

In short — the full version is at the end of [`assessment/INCIDENT.md`](assessment/INCIDENT.md):

1. The **mechanism**, in terms of the RavenDB code that actually runs on this path.
2. Which component **owns the incorrect state**, and when it goes wrong.
3. Why the failure is **intermittent**, and what decides whether a given run survives. Naming a
   general category is not an answer — we want the specific interaction and what opens and closes
   the window in which it goes wrong.
4. A **fix** you would be comfortable shipping, and why the alternatives are worse.
5. A **regression test** that fails before your change and passes after it. Say how confident you are
   that it fails reliably, and on what evidence.
6. **Blast radius** — which other RavenDB features can reach the same state, and what a customer would
   see there.

Write your findings the way you would send them to the customer.

There is no time limit. AI tools, web search, documentation and public source may be used; briefly
state what you used and how you verified it. A technical follow-up conversation is part of the
process.

---

## Notes and troubleshooting

- To point the job at a server you are already running, set `RECONCILIATION_URL` before step 4.
- If `dotnet` on your `PATH` is not the SDK you want, point the scripts at another one with the
  `RAVEN_DOTNET` environment variable.
- Build output (`bin/`, `obj/`) and server data are not shipped; the scripts create them.
- Step 4 overwrites most of `assessment/EVIDENCE/` with your own run and appends a line to
  `EVIDENCE/run-history.txt`. The captures we shipped are there as a starting point, not as ground
  truth.
