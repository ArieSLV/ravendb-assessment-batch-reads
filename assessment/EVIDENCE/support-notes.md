# Support notes on the attached evidence

These notes were written while capturing the artifacts in this directory. They record what
each artifact establishes and, just as importantly, what it does not.

The first thing to understand about this package is that no single capture is
representative. The pass fails in a different place, at a different time, with a different
exception on every run. Read `run-history.txt` before you read anything else.

## run-history.txt

One appended line per capture we have taken, oldest first.

**Establishes**

- The failure is not a one-off. Every capture we have taken ended in an anomaly.
- Nothing about it is stable: the account it dies on, the exception it raises and the
  elapsed time all change from run to run.
- Two distinct symptom classes show up. Either the client throws while the batch is being
  assembled, or the batch completes and hands back an account that is missing or wrong.
  Nothing in the job's own code distinguishes the two cases.
- Time to failure spans roughly two orders of magnitude across captures, but the number of
  account reads that precede it stays in a much narrower band. The failure tracks work
  done, not wall-clock time.

**Does not establish**

- That the two symptom classes have the same cause. They might not.
- Any bound on how long a clean run can last. We have not seen the budget expire, but we
  cannot promise you will not.

## application.log

What the pass printed on the most recent capture. One line per step, plus a progress line
every fifteen seconds, with the counters the client reported at that moment. The
`cacheItems` figure is instrumentation we added while chasing the report; the customer's own
build does not print it.

**Establishes**

- The account book is read once, up front, under aggressive caching, and every later read
  in the pass is expected to be served from the client.
- The anomaly line records how much work had been done when the pass gave up.
- The accounts named in the failing batch are ordinary accounts. The seed wrote them and
  nothing in the job deletes or rewrites accounts.

**Does not establish**

- Which of the ids in the failing batch mattered, if any. The job varies the batch contents
  randomly and does not hold anything fixed.
- Whether the settlement lookup at the head of each batch is involved. It is there because
  the customer's job does it, not because we established it matters.
- Anything about `cacheItems`. It moves constantly because the cache is capped at 1 MB, and
  it moves the same way on runs that stay clean.

## client-stack-traces.txt

The exception the pass caught on that capture, verbatim.

**Establishes**

- The failure surfaces while the lazy batch is being executed, before any of the job's own
  code looks at a result.
- Every frame in the trace belongs to the client.

**Does not establish**

- Anything about the origin of the corrupt state. The trace tells you where the damage
  became visible, not where it was done, and the two are not in the same operation.
- Do not expect the trace to be the same as the one in your own run. Compare it against
  `run-history.txt` first; if the two traces disagree, that is the normal case, not a sign
  that you are looking at a second bug.

## runtime-and-counters.txt

Machine, runtime, core count, target server, budget and the counter lines lifted out of the
same run.

**Establishes**

- The capture was taken on a machine with the stated core count. The customer's box has
  fewer cores than ours and reports the same symptoms.
- The pass issues hundreds of thousands of batches per minute, so the anomaly rate per unit
  of work is very low even when the wall-clock time to failure is short.

**Does not establish**

- Anything about cache entry lifetime, reference counts, or what the client held onto
  between batches. `cacheItems` counts dictionary entries only.

## General caution

The job deliberately keeps the account book small and the documents padded so that the pass
puts pressure on a capped client cache, which is what the customer's deployment does. That
shape makes the anomaly easier to reach; whether it is a precondition for it is exactly the
kind of thing worth establishing rather than assuming.

Reproducing with a larger account book, a different number of workers, a different cache cap
or a different batch shape is a reasonable thing to try, and the result either way is worth
reporting - including the negative results.
