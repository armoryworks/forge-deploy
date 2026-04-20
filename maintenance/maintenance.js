// ── Save where the user was trying to go ──────────────────
// The maintenance container redirects all routes here.
// Capture the original path so we can send them back when the site recovers.
(function () {
  const path = window.location.pathname + window.location.search + window.location.hash;
  // Don't overwrite if we already saved a path (page reloads shouldn't reset it)
  if (!sessionStorage.getItem('qbe-maintenance-return') && path !== '/' && path !== '/maintenance.html') {
    sessionStorage.setItem('qbe-maintenance-return', path);
  }
})();

// ── Health check — polls until the real site is back ───────
const checkInterval = 10;
let countdown = checkInterval;
const el = document.getElementById('countdown');

// Update the countdown display every second
setInterval(() => {
  countdown--;
  if (countdown < 0) countdown = 0;
  if (el) el.textContent = countdown;
}, 1000);

async function checkHealth() {
  try {
    const res = await fetch('/api/v1/health', { cache: 'no-store' });
    if (!res.ok) { countdown = checkInterval; return; }
    // Verify we got a real JSON API response, not the maintenance HTML
    const ct = res.headers.get('content-type') || '';
    if (!ct.includes('application/json')) { countdown = checkInterval; return; }
    // Site is back — redirect to where the user was
    const returnPath = sessionStorage.getItem('qbe-maintenance-return') || '/';
    sessionStorage.removeItem('qbe-maintenance-return');
    window.location.href = returnPath;
  } catch {
    // Still down — reset countdown for next check
    countdown = checkInterval;
  }
}
setInterval(checkHealth, checkInterval * 1000);
// Check immediately on load too
checkHealth();
