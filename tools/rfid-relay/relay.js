/**
 * RFID Relay — Local WebSocket server that reads USB RFID/NFC readers
 * and broadcasts card UIDs to connected browser clients.
 *
 * Supports two reader types:
 *   1. PC/SC smart card readers (ACR122U, CCID devices) via nfc-pcsc  [default]
 *   2. Raw HID RFID readers via node-hid
 *
 * Usage:
 *   npm start                       # Auto-detect PC/SC readers
 *   node relay.js --mode hid        # Use raw HID mode
 *   node relay.js --mode hid 072f:2200  # HID mode with specific device
 *   node relay.js --port 9877       # Change WebSocket port
 *   node relay.js --mode all        # Listen on both PC/SC and HID
 *
 * The browser connects to ws://localhost:9876 and receives JSON messages:
 *   { "type": "scan", "uid": "A1B2C3D4", "timestamp": "..." }
 *   { "type": "connected", "device": "ACS ACR122U" }
 *   { "type": "disconnected", "device": "ACS ACR122U" }
 *   { "type": "error", "message": "..." }
 */
import { WebSocketServer } from 'ws';

// ── Parse CLI args ──
const args = process.argv.slice(2);
let mode = 'pcsc'; // 'pcsc', 'hid', or 'all'
let targetVidPid = null;
let port = 9876;
let debounceMs = 500;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    port = parseInt(args[i + 1], 10);
    i++;
  } else if (args[i] === '--debounce' && args[i + 1]) {
    debounceMs = parseInt(args[i + 1], 10);
    i++;
  } else if (args[i] === '--mode' && args[i + 1]) {
    mode = args[i + 1];
    i++;
  } else if (args[i].includes(':')) {
    targetVidPid = args[i];
  }
}

// ── WebSocket server ──
const wss = new WebSocketServer({ port });
const activeDevices = new Map(); // name → { mode: 'pcsc'|'hid' }

let lastUid = null;
let lastScanTime = 0;

function broadcast(msg) {
  const data = JSON.stringify(msg);
  for (const client of wss.clients) {
    if (client.readyState === 1) {
      client.send(data);
    }
  }
}

function handleScan(uid, extra = {}) {
  if (!uid) return;
  uid = uid.toUpperCase();

  const now = Date.now();
  if (uid === lastUid && now - lastScanTime < debounceMs) return;
  lastUid = uid;
  lastScanTime = now;

  console.log(`  Card detected: ${uid}`);
  broadcast({
    type: 'scan',
    uid,
    ...extra,
    timestamp: new Date().toISOString(),
  });
}

// ── PC/SC mode (nfc-pcsc) ──
async function startPcsc() {
  let NFC;
  try {
    ({ NFC } = await import('nfc-pcsc'));
  } catch {
    console.error('PC/SC mode unavailable: nfc-pcsc not installed. Run "npm install".');
    if (mode === 'pcsc') process.exit(1);
    return;
  }

  const nfc = new NFC();

  nfc.on('reader', (reader) => {
    const name = reader.reader.name;
    console.log(`[PC/SC] Reader detected: ${name}`);
    activeDevices.set(name, { mode: 'pcsc' });
    broadcast({ type: 'connected', device: name });

    reader.on('card', (card) => {
      handleScan(card.uid, { atr: card.atr?.toString('hex') ?? null });
    });

    reader.on('card.off', (card) => {
      console.log(`  Card removed${card.uid ? ': ' + card.uid.toUpperCase() : ''}`);
    });

    reader.on('error', (err) => {
      console.error(`[PC/SC] Reader error (${name}): ${err.message}`);
      broadcast({ type: 'error', message: `${name}: ${err.message}` });
    });

    reader.on('end', () => {
      console.log(`[PC/SC] Reader disconnected: ${name}`);
      activeDevices.delete(name);
      broadcast({ type: 'disconnected', device: name });
    });
  });

  nfc.on('error', (err) => {
    console.error(`[PC/SC] Error: ${err.message}`);
    if (!err.message?.includes('SCardEstablishContext')) {
      broadcast({ type: 'error', message: err.message });
    }
  });

  console.log('[PC/SC] Waiting for smart card readers...');
}

// ── HID mode (node-hid) ──
async function startHid() {
  let HID;
  try {
    ({ default: HID } = await import('node-hid'));
  } catch {
    console.error('HID mode unavailable: node-hid not installed. Run "npm install".');
    if (mode === 'hid') process.exit(1);
    return;
  }

  function findDevice() {
    const devices = HID.devices();

    if (targetVidPid) {
      const [vid, pid] = targetVidPid.split(':').map(s => parseInt(s, 16));
      const match = devices.find(d => d.vendorId === vid && d.productId === pid);
      if (!match) {
        console.error(`[HID] Device ${targetVidPid} not found. Run "npm run devices" to list devices.`);
        process.exit(1);
      }
      return match;
    }

    // Auto-detect: skip keyboards and mice
    const candidates = devices.filter(d => {
      if (d.usagePage === 1 && (d.usage === 6 || d.usage === 2)) return false;
      if (d.usagePage === 0x0d) return false;
      return true;
    });

    // Prefer devices with RFID-related names
    const rfidKeywords = /rfid|nfc|contactless|smart.?card|acr|reader/i;
    const rfidDevice = candidates.find(d =>
      rfidKeywords.test(d.product || '') || rfidKeywords.test(d.manufacturer || ''));

    if (rfidDevice) return rfidDevice;
    if (candidates.length > 0) {
      console.log(`[HID] No RFID device auto-detected. Using: ${candidates[0].product || candidates[0].path}`);
      return candidates[0];
    }

    console.error('[HID] No suitable HID devices found. Run "npm run devices" to see all devices.');
    if (mode === 'hid') process.exit(1);
    return null;
  }

  function extractUid(data) {
    let start = 0;
    let end = data.length - 1;
    while (start < data.length && data[start] === 0) start++;
    while (end > start && data[end] === 0) end--;
    if (start > end) return null;

    const payload = data.slice(start, end + 1);
    if (payload.length === 0) return null;

    let uidBytes = payload;
    if (payload.length > 1 && payload[0] === payload.length - 1) {
      uidBytes = payload.slice(1);
    }
    if (uidBytes.length === 0) return null;

    return Buffer.from(uidBytes).toString('hex').toUpperCase();
  }

  const deviceInfo = findDevice();
  if (!deviceInfo) return;

  const name = deviceInfo.product || `${deviceInfo.vendorId.toString(16)}:${deviceInfo.productId.toString(16)}`;
  console.log(`[HID] Opening device: ${name} (${deviceInfo.path})`);

  let device;
  try {
    device = new HID.HID(deviceInfo.path);
  } catch (err) {
    console.error(`[HID] Failed to open device: ${err.message}`);
    console.error('On Windows, you may need to run as Administrator.');
    if (mode === 'hid') process.exit(1);
    return;
  }

  activeDevices.set(name, { mode: 'hid' });
  broadcast({ type: 'connected', device: name });
  console.log(`[HID] Listening for scans...`);

  device.on('data', (data) => {
    const uid = extractUid(data);
    if (uid) handleScan(uid, { raw: Array.from(data) });
  });

  device.on('error', (err) => {
    console.error(`[HID] Device error: ${err.message}`);
    activeDevices.delete(name);
    broadcast({ type: 'error', message: err.message });
    broadcast({ type: 'disconnected', device: name });

    console.log('[HID] Reconnecting in 3 seconds...');
    setTimeout(() => {
      try { startHid(); } catch { console.error('[HID] Reconnect failed.'); }
    }, 3000);
  });
}

// ── Start ──
wss.on('listening', async () => {
  console.log(`\nRFID Relay started on ws://localhost:${port}`);
  console.log(`Mode: ${mode} | Debounce: ${debounceMs}ms\n`);

  if (mode === 'pcsc' || mode === 'all') await startPcsc();
  if (mode === 'hid' || mode === 'all') await startHid();
});

wss.on('connection', (ws) => {
  console.log('Browser client connected');
  for (const [name] of activeDevices) {
    ws.send(JSON.stringify({ type: 'connected', device: name }));
  }
});

process.on('SIGINT', () => {
  console.log('\nShutting down...');
  wss.close();
  process.exit(0);
});

process.on('SIGTERM', () => {
  wss.close();
  process.exit(0);
});
