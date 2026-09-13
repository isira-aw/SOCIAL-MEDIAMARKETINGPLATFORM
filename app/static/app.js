/* Shared helpers for the Postly frontend. */

const $ = (id) => document.getElementById(id);

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function setStatus(kind, msg) {
  const el = $('status');
  if (!el) return;
  el.className = 'status show ' + kind;
  el.textContent = msg;
  if (kind === 'ok') setTimeout(() => { el.className = 'status'; }, 4000);
}

/* ------------------------------------------------------------------ *
 * Settings — persisted in localStorage, never sent to a third party.
 * ------------------------------------------------------------------ */
const Settings = (() => {
  const KEY = 'postly.settings.v1';
  const DEFAULTS = {
    business_name: '',
    sector: '',
    tone: 'warm, informative',
    audience: '',
    n8n_webhook_url: '',
    use_n8n: false,
    generate_image: true,
    platforms: ['facebook', 'instagram'],
  };

  function get() {
    try {
      const raw = localStorage.getItem(KEY);
      if (!raw) return { ...DEFAULTS };
      const parsed = JSON.parse(raw);
      return { ...DEFAULTS, ...(parsed && typeof parsed === 'object' ? parsed : {}) };
    } catch (e) {
      return { ...DEFAULTS };
    }
  }

  function set(patch) {
    const next = { ...get(), ...patch };
    try { localStorage.setItem(KEY, JSON.stringify(next)); } catch (e) { /* private mode */ }
    return next;
  }

  function clear() {
    try { localStorage.removeItem(KEY); } catch (e) { /* ignore */ }
  }

  return { get, set, clear, DEFAULTS };
})();

/* Copy-to-clipboard, delegated. Any element with data-copy works. */
document.addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-copy]');
  if (!btn) return;
  const text = btn.dataset.copy;
  const original = btn.textContent;
  try {
    await navigator.clipboard.writeText(text);
    btn.textContent = 'Copied';
  } catch (err) {
    // Fallback for browsers that block the async clipboard API.
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); btn.textContent = 'Copied'; }
    catch (e2) { btn.textContent = 'Failed'; }
    document.body.removeChild(ta);
  }
  setTimeout(() => { btn.textContent = original; }, 1500);
});
