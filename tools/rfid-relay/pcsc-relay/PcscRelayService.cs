using System.Collections.Concurrent;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

using Microsoft.Extensions.Hosting;

using PCSC;
using PCSC.Monitoring;

/// <summary>
/// Configuration options for the RFID relay, parsed from CLI args or defaults.
/// When running as a Windows Service, the service is installed with the defaults
/// (port 9876, debounce 500ms). Override via service ImagePath if needed.
/// </summary>
internal record RelayOptions(int Port = 9876, int DebounceMs = 500);

/// <summary>
/// Hosted service that runs the PC/SC → WebSocket relay.
/// Supports both interactive console mode and unattended Windows Service mode.
/// </summary>
internal sealed class PcscRelayService : BackgroundService
{
    private readonly RelayOptions _opts;

    // WebSocket state
    private readonly ConcurrentBag<WebSocket> _clients = new();
    private readonly ConcurrentDictionary<string, bool> _activeReaders = new();
    private string _lastUid = string.Empty;
    private DateTimeOffset _lastScanTime = DateTimeOffset.MinValue;

    public PcscRelayService(RelayOptions opts) => _opts = opts;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://localhost:{_opts.Port}/");

        try
        {
            listener.Start();
        }
        catch (HttpListenerException ex)
        {
            Console.Error.WriteLine($"[RFID Relay] Failed to start on port {_opts.Port}: {ex.Message}");
            Console.Error.WriteLine("Another process may already be using this port.");
            return;
        }

        Console.WriteLine($"\nRFID Relay (PC/SC) started on ws://localhost:{_opts.Port}");
        Console.WriteLine($"Debounce: {_opts.DebounceMs}ms\n");

        // Start PC/SC monitoring on a background thread
        StartPcscMonitor(stoppingToken);

        // Stop the listener cleanly when the host is stopping
        stoppingToken.Register(() =>
        {
            Console.WriteLine("Shutting down...");
            listener.Stop();
        });

        // Accept WebSocket (and plain HTTP) connections
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                HttpListenerContext context;
                try
                {
                    context = await listener.GetContextAsync();
                }
                catch (HttpListenerException) when (stoppingToken.IsCancellationRequested)
                {
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }

                if (context.Request.IsWebSocketRequest)
                {
                    // Handle WebSocket upgrade on a dedicated task so the accept loop isn't blocked
                    _ = Task.Run(() => HandleWebSocketAsync(context, stoppingToken), stoppingToken);
                }
                else
                {
                    // Simple status page for browser / health-check requests
                    var body = Encoding.UTF8.GetBytes(
                        $"RFID Relay running on ws://localhost:{_opts.Port}");
                    context.Response.ContentType = "text/plain";
                    context.Response.ContentLength64 = body.Length;
                    await context.Response.OutputStream.WriteAsync(body, stoppingToken);
                    context.Response.Close();
                }
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            try { listener.Stop(); } catch { }
        }
    }

    // ── WebSocket handling ────────────────────────────────────────────────────

    private async Task HandleWebSocketAsync(HttpListenerContext context, CancellationToken ct)
    {
        var wsContext = await context.AcceptWebSocketAsync(null);
        var ws = wsContext.WebSocket;
        _clients.Add(ws);
        Console.WriteLine("Browser client connected");

        // Send current reader status to the newly connected client
        foreach (var name in _activeReaders.Keys)
            await SendAsync(ws, new { type = "connected", device = name });

        // Keep the WebSocket alive until the client disconnects or we're stopping
        var buffer = new byte[1024];
        try
        {
            while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
                await ws.ReceiveAsync(buffer, ct);
        }
        catch { }
        finally
        {
            try { ws.Dispose(); } catch { }
        }
    }

    private void Broadcast(object message)
    {
        var bytes = Encode(message);
        var segment = new ArraySegment<byte>(bytes);
        foreach (var ws in _clients)
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

    private static async Task SendAsync(WebSocket ws, object message)
    {
        if (ws.State != WebSocketState.Open) return;
        await ws.SendAsync(Encode(message), WebSocketMessageType.Text, true, CancellationToken.None);
    }

    private static byte[] Encode(object obj) =>
        Encoding.UTF8.GetBytes(JsonSerializer.Serialize(obj));

    // ── PC/SC monitoring ──────────────────────────────────────────────────────

    private void StartPcscMonitor(CancellationToken ct)
    {
        try
        {
            var deviceMonitor = DeviceMonitorFactory.Instance.Create(SCardScope.System);

            deviceMonitor.StatusChanged += (_, e) =>
            {
                foreach (var name in e.DetachedReaders)
                {
                    _activeReaders.TryRemove(name, out bool _);
                    Broadcast(new { type = "disconnected", device = name });
                    Console.WriteLine($"[PC/SC] Reader disconnected: {name}");
                }
                foreach (var name in e.AttachedReaders)
                {
                    if (IsContactOnly(name)) continue;
                    MonitorReader(name);
                }
            };

            deviceMonitor.Start();

            // Monitor readers that are already connected
            using var ctx = ContextFactory.Instance.Establish(SCardScope.System);
            var existing = ctx.GetReaders();
            if (existing.Length == 0)
            {
                Console.WriteLine("[PC/SC] No readers found. Waiting for reader to be connected...");
            }
            else
            {
                Console.WriteLine($"[PC/SC] Found {existing.Length} reader(s):");
                foreach (var name in existing)
                {
                    if (IsContactOnly(name))
                    {
                        Console.WriteLine($"  {name} (contact-only — skipped)");
                        continue;
                    }
                    Console.WriteLine($"  {name} (monitoring)");
                    MonitorReader(name);
                }
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[PC/SC] Startup error: {ex.Message}");
            if (ex.Message.Contains("Service") || ex.Message.Contains("service"))
                Console.Error.WriteLine("Ensure the Windows 'Smart Card' service is running (sc start SCardSvr).");
        }
    }

    private void MonitorReader(string readerName)
    {
        _activeReaders[readerName] = true;
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
                    if (uid != null) HandleScan(uid, e.ReaderName);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[PC/SC] Error reading card: {ex.Message}");
                }
            };

            monitor.CardRemoved += (_, e) =>
                Console.WriteLine($"[PC/SC] Card removed from {e.ReaderName}");

            monitor.MonitorException += (_, e) =>
                Console.Error.WriteLine($"[PC/SC] Monitor error on {readerName}: {e.SCardError}");

            monitor.Start(readerName);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[PC/SC] Failed to monitor {readerName}: {ex.Message}");
        }
    }

    private string? ReadCardUid(string readerName)
    {
        using var ctx = ContextFactory.Instance.Establish(SCardScope.System);
        using var reader = ctx.ConnectReader(readerName, SCardShareMode.Shared, SCardProtocol.Any);

        var getUidApdu = new byte[] { 0xFF, 0xCA, 0x00, 0x00, 0x00 };
        var receiveBuffer = new byte[256];
        var bytesReceived = reader.Transmit(getUidApdu, receiveBuffer);

        if (bytesReceived < 2) return null;

        var sw1 = receiveBuffer[bytesReceived - 2];
        var sw2 = receiveBuffer[bytesReceived - 1];
        if (sw1 != 0x90 || sw2 != 0x00)
        {
            Console.Error.WriteLine($"[PC/SC] APDU error: SW={sw1:X2}{sw2:X2}");
            return null;
        }

        var uidLength = bytesReceived - 2;
        return uidLength <= 0 ? null : Convert.ToHexString(receiveBuffer, 0, uidLength);
    }

    private void HandleScan(string uid, string readerName)
    {
        uid = uid.ToUpperInvariant();
        var now = DateTimeOffset.UtcNow;

        if (uid == _lastUid && (now - _lastScanTime).TotalMilliseconds < _opts.DebounceMs)
            return;

        _lastUid = uid;
        _lastScanTime = now;

        Console.WriteLine($"  Card UID: {uid}");
        Broadcast(new
        {
            type = "scan",
            uid,
            reader = readerName,
            timestamp = now.ToString("o"),
        });
    }

    // Contact/EMV readers (chip slots) don't handle contactless RFID — skip them
    private static bool IsContactOnly(string name) =>
        (name.Contains("EMV", StringComparison.OrdinalIgnoreCase) ||
         (name.Contains("Contact", StringComparison.OrdinalIgnoreCase) &&
          !name.Contains("Contactless", StringComparison.OrdinalIgnoreCase)));
}
