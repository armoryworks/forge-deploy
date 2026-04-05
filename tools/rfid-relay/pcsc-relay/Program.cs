using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using PCSC;

// ── --list mode: print readers and exit (no host needed) ──────────────────────
if (args.Contains("--list"))
{
    ListReaders(args);
    return;
}

// ── Parse CLI args ─────────────────────────────────────────────────────────────
var port = 9876;
var debounceMs = 500;

for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--port" && i + 1 < args.Length)
        port = int.Parse(args[++i]);
    else if (args[i] == "--debounce" && i + 1 < args.Length)
        debounceMs = int.Parse(args[++i]);
}

// ── Host setup ────────────────────────────────────────────────────────────────
var builder = Host.CreateApplicationBuilder(args);

// Suppress the default "Application started" / "Hosting started" console noise
builder.Logging.SetMinimumLevel(Microsoft.Extensions.Logging.LogLevel.Warning);

if (OperatingSystem.IsWindows())
{
    builder.Services.AddWindowsService(options =>
        options.ServiceName = "QB Engineer RFID Relay");
}

builder.Services.AddSingleton(new RelayOptions(port, debounceMs));
builder.Services.AddHostedService<PcscRelayService>();

await builder.Build().RunAsync();

// ── --list helper (standalone, no host) ───────────────────────────────────────
static void ListReaders(string[] args)
{
    Console.WriteLine("\n=== PC/SC Smart Card Readers ===\n");
    try
    {
        using var ctx = ContextFactory.Instance.Establish(SCardScope.System);
        var readers = ctx.GetReaders();

        if (readers.Length == 0)
        {
            Console.WriteLine("No PC/SC readers found.");
            Console.WriteLine("\nTroubleshooting:");
            Console.WriteLine("  1. Ensure the reader is plugged in");
            Console.WriteLine("  2. Check Device Manager > Smart card readers");
            Console.WriteLine("  3. Ensure the 'Smart Card' Windows service is running");
        }
        else
        {
            foreach (var name in readers)
                Console.WriteLine($"  {name}");
            Console.WriteLine($"\n{readers.Length} reader(s) found.");
        }
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"Error: {ex.Message}");
    }
    Console.WriteLine();
}
