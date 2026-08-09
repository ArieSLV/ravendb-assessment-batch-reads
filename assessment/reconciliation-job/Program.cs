using System;
using System.Linq;
using System.Net.Http;
using Raven.Client.Documents;
using Raven.Client.ServerWide;
using Raven.Client.ServerWide.Operations;
using Sparrow;

namespace ReconciliationJob
{
    public static class Program
    {
        private const string DefaultUrl = "http://127.0.0.1:8080";
        private const string DefaultDatabase = "reconciliation";
        private const int DefaultWorkers = 16;
        private const double DefaultMinutes = 5;

        public static int Main(string[] args)
        {
            var url = ArgumentOrDefault(args, "--url", DefaultUrl);
            var database = ArgumentOrDefault(args, "--database", DefaultDatabase);
            var workers = IntArgument(args, "--workers", DefaultWorkers);
            var minutes = DoubleArgument(args, "--minutes", DefaultMinutes);

            if (ServerIsReachable(url, out var why) == false)
            {
                Console.Error.WriteLine($"cannot reach a RavenDB server at {url}: {why}");
                Console.Error.WriteLine("start one first, see assessment/scripts/start-server.ps1");
                return 2;
            }

            ResetDatabase(url, database);

            using (var store = new DocumentStore
            {
                Urls = new[] { url },
                Database = database,
                // the customer runs several dozen of these jobs on one box and caps the client cache
                // so that they do not compete for memory
                Conventions = { MaxHttpCacheSize = new Size(1, SizeUnit.Megabytes) }
            }.Initialize())
            {
                var run = new ReconciliationRun(store, workers, TimeSpan.FromMinutes(minutes));
                return run.Execute();
            }
        }

        private static string ArgumentOrDefault(string[] args, string name, string fallback)
        {
            var index = Array.FindIndex(args, a => string.Equals(a, name, StringComparison.OrdinalIgnoreCase));
            if (index >= 0 && index + 1 < args.Length)
                return args[index + 1];

            var inline = args.FirstOrDefault(a => a.StartsWith(name + "=", StringComparison.OrdinalIgnoreCase));
            return inline != null ? inline.Substring(name.Length + 1) : fallback;
        }

        private static int IntArgument(string[] args, string name, int fallback)
        {
            var raw = ArgumentOrDefault(args, name, null);
            return raw != null && int.TryParse(raw, out var value) && value > 0 ? value : fallback;
        }

        private static double DoubleArgument(string[] args, string name, double fallback)
        {
            var raw = ArgumentOrDefault(args, name, null);
            return raw != null && double.TryParse(raw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value) && value > 0 ? value : fallback;
        }

        private static bool ServerIsReachable(string url, out string why)
        {
            try
            {
                using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) })
                {
                    var response = http.GetAsync($"{url.TrimEnd('/')}/build/version").GetAwaiter().GetResult();
                    if (response.IsSuccessStatusCode)
                    {
                        why = null;
                        return true;
                    }

                    why = $"{(int)response.StatusCode} {response.ReasonPhrase}";
                    return false;
                }
            }
            catch (Exception e)
            {
                why = e.GetBaseException().Message;
                return false;
            }
        }

        private static void ResetDatabase(string url, string database)
        {
            using (var admin = new DocumentStore { Urls = new[] { url } }.Initialize())
            {
                try
                {
                    admin.Maintenance.Server.Send(new DeleteDatabasesOperation(database, hardDelete: true));
                }
                catch
                {
                    // first run on a fresh server, nothing to remove
                }

                admin.Maintenance.Server.Send(new CreateDatabaseOperation(new DatabaseRecord(database)));
            }
        }
    }
}
