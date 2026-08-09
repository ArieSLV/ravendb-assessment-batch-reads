using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Raven.Client.Documents;
using Raven.Client.Http;

namespace ReconciliationJob
{
    /// <summary>
    /// The nightly reconciliation pass, as the customer runs it, with a little extra logging added
    /// while we were chasing the report.
    ///
    /// Every worker walks its share of the account book. For each account it first asks whether a
    /// settlement record already exists for tonight - most of the time it does not - and then
    /// re-reads a handful of accounts to compare balances. The lookups are issued as one lazy batch
    /// so that the whole check costs a single round trip, and the pass runs under aggressive caching
    /// because the account book barely changes during the night.
    /// </summary>
    public sealed class ReconciliationRun
    {
        private const int AccountCount = 200;
        private const int AccountsPerCheck = 4;

        private readonly IDocumentStore _store;
        private readonly int _workers;
        private readonly TimeSpan _budget;

        private readonly ConcurrentQueue<string> _anomalies = new ConcurrentQueue<string>();
        private readonly Stopwatch _clock = new Stopwatch();
        private readonly object _reporting = new object();

        private long _rounds;
        private long _accountsChecked;

        public ReconciliationRun(IDocumentStore store, int workers, TimeSpan budget)
        {
            _store = store;
            _workers = workers;
            _budget = budget;
        }

        public int Execute()
        {
            Log($"job start      | target={_store.Urls[0]} database={_store.Database} workers={_workers} budget={_budget.TotalMinutes:0.#}m");

            SeedAccountBook();

            using (_store.AggressivelyCacheFor(TimeSpan.FromMinutes(30), AggressiveCacheMode.DoNotTrackChanges))
            {
                WarmAccountBook();
                RunPass();
            }

            var anomaly = DrainAnomalies();
            var exitCode = anomaly != null ? 1 : 0;

            Log($"job end        | exit={exitCode} rounds={Interlocked.Read(ref _rounds)} accountsChecked={Interlocked.Read(ref _accountsChecked)} elapsed={_clock.Elapsed.TotalSeconds:0.0}s cacheItems={CacheItems()}");

            if (anomaly == null)
            {
                Log("job end        | no anomaly on this run - see assessment/INCIDENT.md, the pass does not fail every night");
            }

            return exitCode;
        }

        private void SeedAccountBook()
        {
            var memo = string.Join(" ", CreateMemoLines());

            using (var bulk = _store.BulkInsert())
            {
                for (int i = 0; i < AccountCount; i++)
                {
                    bulk.Store(new Account
                    {
                        Holder = HolderOf(i),
                        Balance = BalanceOf(i),
                        Memo = memo
                    }, AccountId(i));
                }
            }

            Log($"seed           | {AccountCount} accounts written, accounts/0 .. accounts/{AccountCount - 1}");
        }

        private void WarmAccountBook()
        {
            using (var session = _store.OpenSession())
            {
                session.Advanced.MaxNumberOfRequestsPerSession = AccountCount + 100;

                for (int i = 0; i < AccountCount; i++)
                    session.Advanced.Lazily.Load<Account>(AccountId(i));

                session.Advanced.Eagerly.ExecuteAllPendingLazyOperations();
                Log($"warm           | account book read once under aggressive cache, requests={session.Advanced.NumberOfRequests}, cacheItems={CacheItems()}");
            }
        }

        private void RunPass()
        {
            Log($"pass start     | each round asks for tonight's settlement record and then re-reads {AccountsPerCheck} accounts in one lazy batch");

            var stop = new CancellationTokenSource();
            _clock.Start();

            var settlements = Task.Run(() => WriteSettlements(stop.Token));

            var workers = new List<Task>();
            for (int w = 0; w < _workers; w++)
            {
                var worker = w;
                workers.Add(Task.Run(() => Reconcile(worker)));
            }

            var progress = Task.Run(() => ReportProgress(stop.Token));

            Task.WaitAll(workers.ToArray());
            _clock.Stop();

            stop.Cancel();

            try
            {
                Task.WaitAll(settlements, progress);
            }
            catch (AggregateException)
            {
                // both are cancellation-driven, nothing here is part of the result
            }
        }

        private void Reconcile(int worker)
        {
            var rng = new Random(worker * 7919 + 13);

            while (_anomalies.IsEmpty && _clock.Elapsed < _budget)
            {
                var round = Interlocked.Increment(ref _rounds);
                var ids = new List<string>();

                try
                {
                    using (var session = _store.OpenSession())
                    {
                        session.Advanced.MaxNumberOfRequestsPerSession = 10_000;

                        // has tonight's settlement already been written for this worker's slice?
                        // for most rounds it has not, and the lookup comes back empty
                        session.Advanced.Lazily.Load<Settlement>($"settlements/pending/{worker}/{round}");

                        var picked = new HashSet<int>();
                        while (picked.Count < AccountsPerCheck)
                            picked.Add(rng.Next(AccountCount));

                        var lazies = new List<Lazy<Account>>();
                        foreach (var i in picked)
                        {
                            ids.Add(AccountId(i));
                            lazies.Add(session.Advanced.Lazily.Load<Account>(AccountId(i)));
                        }

                        session.Advanced.Eagerly.ExecuteAllPendingLazyOperations();

                        for (int j = 0; j < lazies.Count; j++)
                        {
                            var account = lazies[j].Value;
                            var index = IndexOf(ids[j]);

                            if (account == null)
                            {
                                Report($"{ids[j]} came back <missing>, but the seed wrote it and nothing deletes accounts");
                                continue;
                            }

                            if (account.Holder != HolderOf(index))
                                Report($"{ids[j]} came back with holder '{Printable(account.Holder)}', expected '{HolderOf(index)}'");
                            else if (account.Balance != BalanceOf(index))
                                Report($"{ids[j]} came back with balance {account.Balance}, expected {BalanceOf(index)}");

                            Interlocked.Increment(ref _accountsChecked);
                        }
                    }
                }
                catch (Exception e)
                {
                    Report($"the batch over [{string.Join(", ", ids)}] threw {e.GetType().FullName}: {e.Message}", e);
                }
            }
        }

        private void WriteSettlements(CancellationToken token)
        {
            var memo = string.Join(" ", CreateMemoLines());
            var n = 0;

            while (token.IsCancellationRequested == false)
            {
                try
                {
                    var id = $"settlements/{n}";

                    using (var session = _store.OpenSession())
                    {
                        session.Store(new Settlement { Reference = id, Memo = memo }, id);
                        session.SaveChanges();
                    }

                    using (var session = _store.OpenSession())
                        session.Advanced.Lazily.Load<Settlement>(id).Value?.GetType();

                    n++;
                }
                catch (Exception)
                {
                    // the settlement writer is background noise for this pass, its own failures are
                    // not what we are chasing
                }

                Thread.Yield();
            }
        }

        private void ReportProgress(CancellationToken token)
        {
            var next = TimeSpan.FromSeconds(15);

            while (token.IsCancellationRequested == false)
            {
                Thread.Sleep(250);

                if (_clock.Elapsed < next)
                    continue;

                Log($"pass           | elapsed={_clock.Elapsed.TotalSeconds:0}s rounds={Interlocked.Read(ref _rounds)} accountsChecked={Interlocked.Read(ref _accountsChecked)} cacheItems={CacheItems()}");
                next += TimeSpan.FromSeconds(15);
            }
        }

        private void Report(string message, Exception exception = null)
        {
            _anomalies.Enqueue(message);

            // workers report concurrently, and the exception block below has to come out in one
            // piece or the capture script picks up somebody else's line inside it
            lock (_reporting)
            {
                Log($"anomaly        | after {_clock.Elapsed.TotalSeconds:0.0}s / {Interlocked.Read(ref _rounds)} rounds / {Interlocked.Read(ref _accountsChecked)} account reads: {message}");

                if (exception == null)
                    return;

                Console.Out.WriteLine();
                Console.Out.WriteLine("---- client exception ----");
                Console.Out.WriteLine(exception.ToString());
                Console.Out.WriteLine("---- end client exception ----");
                Console.Out.Flush();
            }
        }

        private string DrainAnomalies()
        {
            string first = null;
            while (_anomalies.TryDequeue(out var anomaly))
                first = first ?? anomaly;

            return first;
        }

        private int CacheItems()
        {
            return _store.GetRequestExecutor().Cache.NumberOfItems;
        }

        private static IEnumerable<string> CreateMemoLines()
        {
            for (int i = 0; i < 20; i++)
                yield return "carried forward from the previous settlement cycle, no manual adjustment recorded";
        }

        private static string AccountId(int index) => $"accounts/{index}";

        private static int IndexOf(string id) => int.Parse(id.Substring("accounts/".Length));

        private static string HolderOf(int index) => $"holder-{index}";

        private static long BalanceOf(int index) => 1000L + index;

        private static string Printable(string value)
        {
            if (value == null)
                return "<null>";

            return value.Length > 40 ? value.Substring(0, 40) + "..." : value;
        }

        private static void Log(string message)
        {
            Console.Out.WriteLine($"{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss.fff}Z  {message}");
        }

        private sealed class Account
        {
            public string Id { get; set; }

            public string Holder { get; set; }

            public long Balance { get; set; }

            public string Memo { get; set; }
        }

        private sealed class Settlement
        {
            public string Id { get; set; }

            public string Reference { get; set; }

            public string Memo { get; set; }
        }
    }
}
