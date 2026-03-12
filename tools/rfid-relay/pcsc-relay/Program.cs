using System.Collections.Concurrent;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

using PCSC;
using PCSC.Monitoring;

var port = 9876;
var debounceMs = 500;

// Parse CLI args
for (var i = 0; i < args.Length; i++)
{
    if (args[i] == "--port" && i + 1 < args.Length)
    {
        port = int.Parse(args[++i]);
    }
    else if (args[i] == "--debounce" && i + 1 < args.Length)
    {
        debounceMs = int.Parse(args[++i]);
    }
    else if (args[i] == "--list")
    {
        ListReaders();
        return;
    }
}

// WebSocket state
var clients = new ConcurrentBag<WebSocket>();
var activeReaders = new ConcurrentDictionary<string, bool>();
var lastUid = "";
var lastScanTime = DateTimeOffset.MinValue;
var cts = new CancellationTokenSource();

// Start HTTP/WebSocket listener
var listener = new HttpListener();
listener.Prefixes.Add($"http://localhost:{port}/");
listener.Start();
Console.WriteLine($"\nRFID Relay (PC/SC) started on ws://localhost:{port}");
Console.WriteLine($"Debounce: {debounceMs}ms\n");

// Start PC/SC monitoring
StartPcscMonitor(cts.Token);

// Handle Ctrl+C
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    Console.WriteLine("\nShutting down...");
    cts.Cancel();
    listener.Stop();
};

// Accept WebSocket connections
try
{
    while (!cts.Token.IsCancellationRequested)
    {
        var context = await listener.GetContextAsync();
        if (context.Request.IsWebSocketRequest)
        {
            var wsContext = await context.AcceptWebSocketAsync(null);
            var ws = wsContext.WebSocket;
            clients.Add(ws);
            Console.WriteLine("Browser client connected");

            // Send current reader status
            foreach (var reader in activeReaders.Keys)
            {
                await SendAsync(ws, new { type = "connected", device = reader });
            }

            // Keep connection alive (read loop)
            _ = Task.Run(async () =>
            {
                var buffer = new byte[1024];
                try
                {
                    while (ws.State == WebSocketState.Open)
                    {
                        await ws.ReceiveAsync(buffer, cts.Token);
                    }
                }
                catch { }
            });
        }
        else
        {
            // Return a simple status page for HTTP requests
            var response = Encoding.UTF8.GetBytes(
                $"RFID Relay running. Connect via WebSocket at ws://localhost:{port}");
            context.Response.ContentType = "text/plain";
            context.Response.ContentLength64 = response.Length;
            await context.Response.OutputStream.WriteAsync(response);
            context.Response.Close();
        }
    }
}
catch (HttpListenerException) when (cts.Token.IsCancellationRequested) { }
catch (ObjectDisposedException) { }

// Contactless/NFC readers are what we want for RFID. Contact/EMV readers need physical chip insertion.
bool IsContactlessReader(string name) =>
    name.Contains("Contactless", StringComparison.OrdinalIgnoreCase) ||
    name.Contains("NFC", StringComparison.OrdinalIgnoreCase) ||
    name.Contains("RFID", StringComparison.OrdinalIgnoreCase) ||
    name.Contains("ACR122", StringComparison.OrdinalIgnoreCase);

bool IsContactReader(string name) =>
    name.Contains("EMV", StringComparison.OrdinalIgnoreCase) ||
    name.Contains("Contact", StringComparison.OrdinalIgnoreCase) &&
    !name.Contains("Contactless", StringComparison.OrdinalIgnoreCase);

void StartPcscMonitor(CancellationToken token)
{
    try
    {
        var contextFactory = ContextFactory.Instance;

        // Monitor for reader attach/detach
        var deviceMonitor = DeviceMonitorFactory.Instance.Create(SCardScope.System);
        deviceMonitor.StatusChanged += (_, e) =>
        {
            Console.WriteLine($"[PC/SC] Reader status changed. Attached: [{string.Join(", ", e.AttachedReaders)}], Detached: [{string.Join(", ", e.DetachedReaders)}]");

            foreach (var name in e.DetachedReaders)
            {
                activeReaders.TryRemove(name, out bool _);
                Broadcast(new { type = "disconnected", device = name });
                Console.WriteLine($"[PC/SC] Reader disconnected: {name}");
            }

            foreach (var name in e.AttachedReaders)
            {
                if (IsContactReader(name) && !IsContactlessReader(name))
                {
                    Console.WriteLine($"[PC/SC] Skipping contact reader: {name}");
                    continue;
                }
                MonitorReader(name);
            }
        };
        deviceMonitor.Start();

        // Find already-connected readers
        using var ctx = contextFactory.Establish(SCardScope.System);
        var readerNames = ctx.GetReaders();

        if (readerNames.Length == 0)
        {
            Console.WriteLine("[PC/SC] No readers found. Waiting for reader connection...");
        }
        else
        {
            Console.WriteLine($"[PC/SC] Found {readerNames.Length} reader(s):");
            foreach (var name in readerNames)
            {
                if (IsContactReader(name) && !IsContactlessReader(name))
                {
                    Console.WriteLine($"  {name} (contact — skipped)");
                    continue;
                }
                Console.WriteLine($"  {name} (monitoring)");
                MonitorReader(name);
            }
        }
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"[PC/SC] Error: {ex.Message}");
        if (ex.Message.Contains("Service") || ex.Message.Contains("service"))
        {
            Console.Error.WriteLine("Ensure the Windows 'Smart Card' service is running.");
        }
    }
}

void MonitorReader(string readerName)
{
    activeReaders[readerName] = true;
    Broadcast(new { type = "connected", device = readerName });
    Console.WriteLine($"[PC/SC] Monitoring reader: {readerName}");

    try
    {
        var monitor = MonitorFactory.Instance.Create(SCardScope.System);
        monitor.CardInserted += (_, e) =>
        {
            Console.WriteLine($"[PC/SC] Card inserted on {e.ReaderName}");
            try
            {
                var uid = ReadCardUid(e.ReaderName);
                if (uid != null)
                {
                    HandleScan(uid, e.ReaderName);
                }
            }
            catch (Exception ex)
            {
                // Don't broadcast transient read errors — these are common when
                // a card is tapped too quickly or is incompatible with the reader
                Console.Error.WriteLine($"[PC/SC] Error reading card: {ex.Message}");
            }
        };

        monitor.CardRemoved += (_, e) =>
        {
            Console.WriteLine($"[PC/SC] Card removed from {e.ReaderName}");
        };

        monitor.MonitorException += (_, e) =>
        {
            Console.Error.WriteLine($"[PC/SC] Monitor error: {e.SCardError}");
        };

        monitor.Start(readerName);
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"[PC/SC] Failed to monitor {readerName}: {ex.Message}");
    }
}

string? ReadCardUid(string readerName)
{
    using var ctx = ContextFactory.Instance.Establish(SCardScope.System);
    using var reader = ctx.ConnectReader(readerName, SCardShareMode.Shared, SCardProtocol.Any);

    // GET UID APDU command: FF CA 00 00 00
    var getUidApdu = new byte[] { 0xFF, 0xCA, 0x00, 0x00, 0x00 };
    var receiveBuffer = new byte[256];
    var bytesReceived = reader.Transmit(getUidApdu, receiveBuffer);

    if (bytesReceived < 2) return null;

    // Last 2 bytes are SW1 SW2 status (90 00 = success)
    var sw1 = receiveBuffer[bytesReceived - 2];
    var sw2 = receiveBuffer[bytesReceived - 1];

    if (sw1 != 0x90 || sw2 != 0x00)
    {
        Console.Error.WriteLine($"[PC/SC] APDU error: SW={sw1:X2}{sw2:X2}");
        return null;
    }

    // UID is everything before the status bytes
    var uidLength = bytesReceived - 2;
    if (uidLength <= 0) return null;

    return Convert.ToHexString(receiveBuffer, 0, uidLength);
}

void HandleScan(string uid, string readerName)
{
    uid = uid.ToUpperInvariant();
    var now = DateTimeOffset.UtcNow;

    if (uid == lastUid && (now - lastScanTime).TotalMilliseconds < debounceMs)
        return;

    lastUid = uid;
    lastScanTime = now;

    Console.WriteLine($"  Card UID: {uid}");
    Broadcast(new
    {
        type = "scan",
        uid,
        reader = readerName,
        timestamp = now.ToString("o"),
    });
}

void Broadcast(object message)
{
    var json = JsonSerializer.Serialize(message);
    var bytes = Encoding.UTF8.GetBytes(json);
    var segment = new ArraySegment<byte>(bytes);

    foreach (var ws in clients)
    {
        if (ws.State == WebSocketState.Open)
        {
            try
            {
                ws.SendAsync(segment, WebSocketMessageType.Text, true, CancellationToken.None)
                    .GetAwaiter().GetResult();
            }
            catch { }
        }
    }
}

async Task SendAsync(WebSocket ws, object message)
{
    if (ws.State != WebSocketState.Open) return;
    var json = JsonSerializer.Serialize(message);
    var bytes = Encoding.UTF8.GetBytes(json);
    await ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
}

void ListReaders()
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
            {
                Console.WriteLine($"  {name}");
            }
            Console.WriteLine($"\n{readers.Length} reader(s) found.");
        }
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"Error: {ex.Message}");
    }
    Console.WriteLine();
}
