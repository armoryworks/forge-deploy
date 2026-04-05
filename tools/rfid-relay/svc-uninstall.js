/**
 * Uninstalls the RFID Relay Windows Service.
 */
import { Service } from 'node-windows';
import { resolve } from 'path';

const svc = new Service({
  name: 'QB Engineer RFID Relay',
  script: resolve('relay.js'),
});

svc.on('uninstall', () => {
  console.log('Service uninstalled.');
});

svc.on('error', (err) => {
  console.error('Service error:', err);
});

svc.uninstall();
