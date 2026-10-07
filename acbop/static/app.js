'use strict';

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

const api = {
  async get(p) { const r = await fetch(p); if (!r.ok) throw new Error(r.status); return r.json(); },
  async post(p, body) {
    const r = await fetch(p, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: body === undefined ? '{}' : JSON.stringify(body),
    });
    if (!r.ok) throw new Error(r.status);
    return r.json();
  },
  async del(p) { const r = await fetch(p, { method: 'DELETE' }); return r.json(); },
};

// ---------------------------------------------------------------- helpers

function ms(t) {
  if (!t) return '—';
  const m = Math.floor(t / 60000);
  const s = ((t % 60000) / 1000).toFixed(3).padStart(6, '0');
  return m ? `${m}:${s}` : s;
}

function ago(ts) {
  if (!ts) return '—';
  const d = Date.now() / 1000 - ts;
  if (d < 60) return `${Math.round(d)}s`;
  if (d < 3600) return `${Math.round(d / 60)}m`;
  if (d < 86400) return `${Math.round(d / 3600)}h`;
  return `${Math.round(d / 86400)}d`;
}

function clock(ts) {
  return new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function el(tag, attrs = {}, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') n.className = v;
    else if (k === 'html') n.innerHTML = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else n.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    n.appendChild(typeof kid === 'object' ? kid : document.createTextNode(String(kid)));
  }
  return n;
}

function bar(value, max, cls = '') {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  return el('div', { class: 'bar ' + cls }, el('i', { style: `width:${pct}%` }));
}

function fill(tbody, rowsArr, emptyMsg, cols) {
  tbody.replaceChildren();
  if (!rowsArr.length) {
    tbody.appendChild(el('tr', {}, el('td', { colspan: String(cols), class: 'empty' }, emptyMsg)));
    return;
  }
  rowsArr.forEach(r => tbody.appendChild(r));
}

// ---------------------------------------------------------------- tabs

let current = 'live';
$$('nav button').forEach(b => b.addEventListener('click', () => {
  $$('nav button').forEach(x => x.classList.toggle('on', x === b));
  $$('.tab').forEach(t => t.classList.toggle('on', t.id === 'tab-' + b.dataset.tab));
  current = b.dataset.tab;
  refreshTab();
}));

// ---------------------------------------------------------------- live

async function refreshLive() {
  let s;
  try { s = await api.get('/api/state'); }
  catch { $('#dot').className = 'dot dead'; $('#conn').textContent = 'api unreachable'; return; }

  $('#dot').className = 'dot ' + (s.connected ? 'live' : 'dead');
  $('#conn').textContent = s.connected
    ? `server ok · ${s.last_packet_age}s ago`
    : 'no packets from AC server';

  $('#s-type').textContent = s.session ? s.session.type : '—';
  $('#s-track').textContent = s.session ? s.session.track : '—';
  $('#s-drivers').textContent = s.drivers.length;
  $('#s-applies').textContent = s.session ? (s.session.applies ? 'yes' : 'off') : '—';

  const rowsArr = s.drivers.map((d, i) => {
    let state;
    if (d.vsc_active) state = el('span', { class: 'pill vsc' }, `CATCH-UP ${d.vsc_remaining}s`);
    else if (!d.loaded) state = el('span', { class: 'pill' }, 'loading');
    else if (d.vsc_uses) state = el('span', { class: 'pill' }, 'boost used');
    else state = el('span', { class: 'pill ok' }, 'racing');

    return el('tr', {},
      el('td', { class: 'num faint' }, i + 1),
      el('td', { class: 'name' }, d.name),
      el('td', { class: 'muted faint' }, d.car_model),
      el('td', { class: 'num' }, d.laps),
      el('td', { class: 'num' }, ms(d.last_laptime_ms)),
      el('td', { class: 'num' }, ms(d.best_laptime_ms)),
      el('td', { class: 'num' }, `${d.ballast}`),
      el('td', { class: 'num' }, `${d.restrictor}`),
      el('td', {}, state),
      el('td', {}, el('button', {
        class: 'act tiny',
        title: 'Grant catch-up now',
        onclick: () => api.post(`/api/vsc/${d.car_id}`).then(refreshLive),
      }, 'boost')),
    );
  });
  fill($('#grid'), rowsArr, 'Nobody on track', 10);

  $('#log').replaceChildren(...(s.events || []).map(e =>
    el('div', { class: e.level === 'warn' ? 'warn' : '' },
      el('time', {}, clock(e.ts)), e.message)));
}

$('#btn-recompute').addEventListener('click', async (e) => {
  e.target.disabled = true;
  $('#recompute-msg').textContent = 'fitting…';
  try {
    const r = await api.post('/api/recompute');
    $('#recompute-msg').textContent =
      `${r.laps_used} laps · ${r.drivers_rated} rated · ${r.handicaps_updated} handicaps updated`;
  } catch { $('#recompute-msg').textContent = 'failed'; }
  e.target.disabled = false;
});

$('#btn-apply').addEventListener('click', async () => {
  const r = await api.post('/api/apply');
  $('#recompute-msg').textContent = `applied to ${r.drivers} driver(s)`;
});

// ---------------------------------------------------------------- drivers

async function refreshDrivers() {
  const ds = await api.get('/api/drivers');
  fill($('#drivers'), ds.map(d => el('tr', {},
    el('td', { class: 'name' }, d.name),
    el('td', { class: 'num' }, d.pace_pct === null ? '—'
      : (d.pace_pct > 0 ? '+' : '') + d.pace_pct.toFixed(2) + '%'),
    el('td', { class: 'num' }, d.skill_n || 0),
    el('td', {}, d.rated
      ? el('span', { class: 'pill ok' }, 'rated')
      : el('span', { class: 'pill warn' }, 'provisional')),
    el('td', { class: 'num faint' }, ago(d.last_seen)),
    el('td', {}, el('input', {
      type: 'checkbox', ...(d.enabled ? { checked: 'checked' } : {}),
      onchange: (e) => api.post('/api/drivers/' + encodeURIComponent(d.guid),
        { enabled: e.target.checked }),
    })),
  )), 'No drivers seen yet', 6);
}

// ---------------------------------------------------------------- handicaps

async function refreshHandicaps() {
  const track = $('#track-filter').value;
  const hs = await api.get('/api/handicaps' + (track ? '?track=' + encodeURIComponent(track) : ''));

  if ($('#track-filter').options.length <= 1) {
    const m = await api.get('/api/model');
    m.tracks.forEach(t => $('#track-filter').appendChild(el('option', { value: t }, t)));
  }

  const save = (h, patch) => api.post('/api/handicaps', {
    guid: h.guid, track: h.track, car_model: h.car_model,
    restrictor: h.restrictor, ballast: h.ballast, manual: true, ...patch,
  }).then(refreshHandicaps);

  fill($('#handicaps'), hs.map(h => el('tr', {},
    el('td', { class: 'name' }, h.name || h.guid.slice(0, 10)),
    el('td', { class: 'muted' }, h.track),
    el('td', { class: 'muted faint' }, h.car_model),
    el('td', { class: 'num' },
      el('input', {
        class: 'mini', type: 'number', step: '5', value: Math.round(h.ballast),
        onchange: (e) => save(h, { ballast: parseFloat(e.target.value) }),
      })),
    el('td', { class: 'num' },
      el('input', {
        class: 'mini', type: 'number', step: '1', value: h.restrictor,
        onchange: (e) => save(h, { restrictor: parseFloat(e.target.value) }),
      })),
    el('td', {}, h.manual
      ? el('span', { class: 'pill warn' }, 'pinned')
      : el('span', { class: 'pill' }, 'auto')),
    el('td', {}, h.manual ? el('button', {
      class: 'act tiny',
      onclick: () => api.del(`/api/handicaps/${encodeURIComponent(h.guid)}/${encodeURIComponent(h.track)}/${encodeURIComponent(h.car_model)}`).then(refreshHandicaps),
    }, 'unpin') : ''),
  )), 'No handicaps computed yet — run a session, then Recompute', 7);
}

$('#track-filter').addEventListener('change', refreshHandicaps);

// ---------------------------------------------------------------- laps

async function refreshLaps() {
  const ls = await api.get('/api/laps');
  fill($('#laps'), ls.map(l => el('tr', {},
    el('td', { class: 'faint num' }, clock(l.ts)),
    el('td', { class: 'name' }, l.name || l.guid.slice(0, 10)),
    el('td', { class: 'muted' }, l.track),
    el('td', { class: 'muted faint' }, l.car_model),
    el('td', { class: 'num' }, ms(l.laptime_ms)),
    el('td', { class: 'num faint' }, Math.round(l.ballast)),
    el('td', { class: 'num faint' }, l.restrictor),
    el('td', {}, l.clean
      ? el('span', { class: 'pill ok' }, 'counted')
      : el('span', { class: 'pill bad' }, l.reason || 'dropped')),
  )), 'No laps recorded yet', 8);
}

// ---------------------------------------------------------------- model

async function refreshModel() {
  const m = await api.get('/api/model');
  fill($('#trackcar'), m.track_car.map(t => el('tr', {},
    el('td', {}, t.track),
    el('td', { class: 'muted faint' }, t.car_model),
    el('td', { class: 'num' }, t.base_log ? ms(Math.exp(t.base_log)) : '—'),
    el('td', { class: 'num faint' }, t.samples),
  )), 'Nothing fitted yet', 4);

  fill($('#sens'), m.sensitivity.map(s => el('tr', {},
    el('td', {}, s.car_model),
    s.track
      ? el('td', { class: 'muted' }, s.track)
      : el('td', {}, el('span', { class: 'pill' }, 'all tracks')),
    el('td', { class: 'num' }, (s.k_restrictor * 100).toFixed(3) + '%'),
    el('td', { class: 'num' }, (s.k_ballast * 100).toFixed(3) + '%'),
    el('td', { class: 'num faint' }, s.samples),
  )), 'Nothing fitted yet', 5);

  fill($('#affinity'), (m.affinity || []).map(a => el('tr', {},
    el('td', { class: 'name' }, a.name || a.guid.slice(0, 10)),
    el('td', { class: 'muted' }, a.track),
    el('td', { class: 'num' }, (a.value > 0 ? '+' : '') + (a.value * 100).toFixed(2) + '%'),
    el('td', { class: 'num faint' }, a.samples),
  )), 'No track-specific pattern found yet', 4);

  const ss = await api.get('/api/sessions');
  fill($('#sessions'), ss.map(s => el('tr', {},
    el('td', { class: 'faint' }, new Date(s.started * 1000).toLocaleString()),
    el('td', {}, s.track),
    el('td', { class: 'muted' }, s.session_type),
    el('td', { class: 'num' }, s.clean_laps),
  )), 'No sessions yet', 4);
}

// ---------------------------------------------------------------- settings

const GROUPS = [
  ['Handicap shape', [
    ['restrictor_share', 'Restrictor share', 'Fraction delivered as restrictor; rest is ballast. 0.6 = 60/40.'],
    ['max_restrictor', 'Max restrictor %', ''],
    ['max_ballast', 'Max ballast kg', ''],
    ['floor_restrictor', 'Floor restrictor %', 'Everyone carries at least this, giving the catch-up something to give back.'],
    ['floor_ballast', 'Floor ballast kg', ''],
    ['target_percentile', 'Target quantile', '1.0 = slow everyone to the slowest driver. 0.85 ignores one extreme outlier.'],
  ]],
  ['Convergence', [
    ['damping', 'Damping', 'Fraction of the computed change applied each recompute.'],
    ['max_restrictor_step', 'Max restrictor step', ''],
    ['max_ballast_step', 'Max ballast step', ''],
    ['min_laps_for_rating', 'Min clean laps to rate', ''],
    ['half_life_days', 'Lap half-life (days)', 'Old laps decay so improving drivers are not held back.'],
    ['recompute_after_session', 'Refit after each session', ''],
  ]],
  ['Lap filtering', [
    ['drop_cut_laps', 'Reject cut laps', ''],
    ['collision_cooldown_s', 'Contact cooldown (s)', 'Laps within this long of a collision are ignored.'],
    ['trim_fraction', 'Keep best fraction', '0.5 = use each driver’s quickest half.'],
    ['outlier_ratio', 'Outlier cutoff', 'Drop laps slower than this multiple of a personal best.'],
  ]],
  ['Catch-up (VSC)', [
    ['vsc_enabled', 'Enabled', ''],
    ['vsc_command', 'Chat command', ''],
    ['vsc_duration_s', 'Duration (s)', ''],
    ['vsc_min_gap_s', 'Min gap ahead (s)', 'Stops it becoming push-to-pass in a close fight.'],
    ['vsc_min_lap', 'Earliest lap', ''],
    ['vsc_per_session', 'Uses per race', ''],
    ['vsc_forbid_final_lap', 'Block on final lap', ''],
    ['vsc_race_only', 'Race sessions only', ''],
  ]],
  ['Application', [
    ['apply_in_practice', 'Apply in practice', ''],
    ['apply_in_qualify', 'Apply in qualifying', ''],
    ['apply_in_race', 'Apply in race', ''],
    ['announce_handicaps', 'Tell drivers their BoP', ''],
    ['deadband_restrictor', 'Restrictor deadband', 'Do not resend unless it moved this much.'],
    ['deadband_ballast', 'Ballast deadband', ''],
  ]],
  ['Priors', [
    ['prior_k_restrictor', 'Laptime per 1% restrictor', 'Starting guess, e.g. 0.002 = 0.2%.'],
    ['prior_k_ballast', 'Laptime per 10 kg', ''],
    ['sensitivity_prior_weight', 'Prior strength', 'Pseudo-laps anchoring the prior against noisy data.'],
  ]],
  ['Connection (restart required)', [
    ['listen_host', 'Plugin listen host', 'Must match UDP_PLUGIN_ADDRESS in server_cfg.ini.'],
    ['listen_port', 'Plugin listen port', ''],
    ['server_host', 'AC server host', ''],
    ['server_port', 'AC server port', 'Must match UDP_PLUGIN_LOCAL_PORT.'],
    ['realtime_interval_ms', 'Car update interval (ms)', ''],
    ['web_port', 'Web port', ''],
  ]],
];

let cfgCache = {};

async function refreshSettings() {
  cfgCache = await api.get('/api/config');
  const wrap = $('#settings');
  wrap.replaceChildren();
  for (const [title, items] of GROUPS) {
    const g = el('div', { class: 'group' }, el('h3', {}, title));
    for (const [key, label, hint] of items) {
      const val = cfgCache[key];
      const input = typeof val === 'boolean'
        ? el('input', { type: 'checkbox', 'data-key': key, ...(val ? { checked: 'checked' } : {}) })
        : el('input', {
            type: typeof val === 'number' ? 'number' : 'text',
            class: 'mini', step: 'any', 'data-key': key, value: String(val),
          });
      g.appendChild(el('div', { class: 'field' },
        el('label', {}, label, hint ? el('span', { class: 'hint' }, hint) : ''),
        input));
    }
    wrap.appendChild(g);
  }
}

$('#btn-save').addEventListener('click', async () => {
  const patch = {};
  $$('#settings input').forEach(i => {
    patch[i.dataset.key] = i.type === 'checkbox' ? i.checked : i.value;
  });
  const r = await api.post('/api/config', patch);
  cfgCache = r.config;
  $('#save-msg').textContent = r.changed.length
    ? `saved: ${r.changed.join(', ')}` : 'no changes';
  setTimeout(() => { $('#save-msg').textContent = ''; }, 4000);
});

// ---------------------------------------------------------------- loop

function refreshTab() {
  if (current === 'live') refreshLive();
  else if (current === 'drivers') refreshDrivers();
  else if (current === 'handicaps') refreshHandicaps();
  else if (current === 'laps') refreshLaps();
  else if (current === 'model') refreshModel();
  else if (current === 'settings') refreshSettings();
}

refreshLive();
setInterval(() => { if (current === 'live') refreshLive(); }, 1500);
