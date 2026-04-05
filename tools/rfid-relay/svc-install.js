/**
 * Installs the RFID Relay as a Windows Service using node-windows.
 * Usage: node svc-install.js [--port 9876] [--debounce 500]
 */
import { Service } from 'node-windows';
import { resolve } from 'path';

const args = process.argv.slice(2);
let port = 9876;
let debounceMs = 500;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) { port = parseInt(args[i + 1], 10); i++; }
  if (args[i] === '--debounce' && args[i + 1]) { debounceMs = parseInt(args[i + 1], 10); i++; }
}

const svc = new Service({
  name: 'QB Engineer RFID Relay',
  description: `Bridges USB NFC/RFID readers to the QB Engineer browser app via WebSocket (ws://localhost:${port}).`,
  script: resolve('relay.js'),
  scriptOptions: `--port ${port} --debounce ${debounceMs}`,
  nodeOptions: [],
  workingDirectory: resolve('.'),
});

svc.on('install', () => {
  console.log('Service installed. Starting...');
  svc.start();
});

svc.on('start', () => {
  console.log('Service started successfully.');
});

svc.on('alreadyinstalled', () => {
  console.log('Service is already installed.');
});

svc.on('error', (err) => {
  console.error('Service error:', err);
});

svc.install();
