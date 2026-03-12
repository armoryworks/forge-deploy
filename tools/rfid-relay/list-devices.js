/**
 * Lists all connected RFID/NFC-capable devices across both PC/SC and HID transports.
 * Run this to find your reader and determine which mode to use.
 *
 * Usage: npm run devices
 */

console.log('\n=== RFID Device Scanner ===\n');

// ── PC/SC readers ──
console.log('── PC/SC Smart Card Readers ──');
try {
  const { NFC } = await import('nfc-pcsc');
  const nfc = new NFC();
  const pcscReaders = [];

  nfc.on('reader', (reader) => {
    const name = reader.reader.name;
    pcscReaders.push(name);
    console.log(`  Found: ${name}`);

    reader.on('card', (card) => {
      console.log(`\n  Card on ${name}:`);
      console.log(`    UID:      ${card.uid?.toUpperCase() ?? '(not available)'}`);
      console.log(`    ATR:      ${card.atr?.toString('hex') ?? '(not available)'}`);
      console.log(`    Standard: ${card.standard ?? '(unknown)'}\n`);
    });

    reader.on('card.off', () => {
      console.log(`  Card removed from ${name}`);
    });
  });

  nfc.on('error', (err) => {
    if (err.message?.includes('SCardEstablishContext')) {
      console.log('  Windows Smart Card service not running.');
      console.log('  Start via: services.msc → "Smart Card" → Start\n');
    } else {
      console.log(`  Error: ${err.message}\n`);
    }
  });

  // Wait for PC/SC detection
  await new Promise(resolve => setTimeout(resolve, 2000));

  if (pcscReaders.length === 0) {
    console.log('  No PC/SC readers found.\n');
  } else {
    console.log(`  ${pcscReaders.length} PC/SC reader(s) found.\n`);
  }
} catch {
  console.log('  nfc-pcsc not installed. Run "npm install" to enable PC/SC support.\n');
}

// ── HID devices ──
console.log('── HID Devices ──');
try {
  const HID = (await import('node-hid')).default;
  const devices = HID.devices();

  // Filter out keyboards and mice
  const rfidKeywords = /rfid|nfc|contactless|smart.?card|acr|reader/i;
  const candidates = devices.filter(d => {
    if (d.usagePage === 1 && (d.usage === 6 || d.usage === 2)) return false;
    if (d.usagePage === 0x0d) return false;
    return true;
  });

  // Group by vendor:product
  const grouped = new Map();
  for (const d of candidates) {
    const key = `${d.vendorId.toString(16).padStart(4, '0')}:${d.productId.toString(16).padStart(4, '0')}`;
    if (!grouped.has(key)) {
      grouped.set(key, { ...d, interfaces: [], isRfid: false });
    }
    const entry = grouped.get(key);
    entry.interfaces.push(d.interface);
    if (rfidKeywords.test(d.product || '') || rfidKeywords.test(d.manufacturer || '')) {
      entry.isRfid = true;
    }
  }

  if (grouped.size === 0) {
    console.log('  No non-keyboard/mouse HID devices found.\n');
  } else {
    for (const [vidPid, d] of grouped) {
      const name = d.product || d.manufacturer || '(unnamed)';
      const rfidTag = d.isRfid ? ' ← likely RFID' : '';
      console.log(`  ${vidPid}  ${name}${rfidTag}`);
      console.log(`           manufacturer: ${d.manufacturer || '—'}`);
      console.log(`           interfaces:   ${d.interfaces.join(', ')}`);
      console.log();
    }
  }
} catch {
  console.log('  node-hid not installed. Run "npm install" to enable HID support.\n');
}

console.log('── Usage ──');
console.log('  PC/SC reader:   npm start                     (default mode)');
console.log('  HID reader:     npm run start:hid');
console.log('  Specific HID:   node relay.js --mode hid 072f:2200');
console.log('  Both:           node relay.js --mode all');
console.log('\nPlace a card on a PC/SC reader above to see its UID.');
console.log('Press Ctrl+C to stop.\n');
