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

const clock = (ts) =>
  new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });

function el(tag, attrs = {}, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') n.className = v;
    else if (k === 'html') n.innerHTML = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else if (v !== null && v !== undefined && v !== false) n.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false || kid === '') continue;
    n.appendChild(typeof kid === 'object' ? kid : document.createTextNode(String(kid)));
  }
  return n;
}

/**
 * Update a table body in place.
 *
 * Replacing innerHTML every poll is what made the page flicker: it destroys and
 * rebuilds every node, which resets scroll position, kills text selection, and
 * blows away whatever the user was typing into an input. Instead each row is
 * keyed, matched to its existing DOM node, and only the cells whose text
 * actually changed get written. Rows the user is currently editing are skipped
 * entirely.
 *
 *   rows: [{ key, cells: [...], cls? }]
 */
function syncTable(tbody, rows, emptyMsg, colCount) {
  const existing = new Map();
  for (const tr of Array.from(tbody.children)) {
    if (tr.dataset.key) existing.set(tr.dataset.key, tr);
    else tr.remove(); // the "empty" placeholder
  }

  if (!rows.length) {
    if (!tbody.querySelector('.empty')) {
      tbody.replaceChildren(
        el('tr', {}, el('td', { colspan: String(colCount), class: 'empty' }, emptyMsg)),
      );
    }
    return;
  }

  const active = document.activeElement;
  let prev = null;

  for (const row of rows) {
    let tr = existing.get(row.key);
    existing.delete(row.key);

    if (!tr) {
      tr = el('tr', { 'data-key': row.key });
      for (const c of row.cells) tr.appendChild(cellNode(c));
      tr.classList.add('row-in');
    } else {
      // Never clobber a cell the user is working in.
      const busy = tr.contains(active) && active !== document.body;
      if (!busy) {
        const tds = tr.children;
        for (let i = 0; i < row.cells.length; i++) {
          if (tds[i]) patchCell(tds[i], row.cells[i]);
          else tr.appendChild(cellNode(row.cells[i]));
        }
        while (tds.length > row.cells.length) tr.lastChild.remove();
      }
    }

    if (row.cls !== undefined) tr.className = (row.cls || '') + (tr.classList.contains('row-in') ? ' row-in' : '');

    // Move into position only when it is actually out of order, so the DOM is
    // left alone in the common case where nothing moved.
    const want = prev ? prev.nextSibling : tbody.firstChild;
    if (tr !== want) tbody.insertBefore(tr, want);
    prev = tr;
  }

  for (const stale of existing.values()) stale.remove();
}

// A cell is either a plain value, or { v, class, title, node }.
function cellNode(c) {
  const spec = (c && typeof c === 'object' && !(c instanceof Node)) ? c : { v: c };
  const td = el('td', { class: spec.class || null, title: spec.title || null });
  if (spec.node) td.appendChild(spec.node);
  else td.textContent = spec.v === null || spec.v === undefined ? '' : String(spec.v);
  return td;
}

function patchCell(td, c) {
  const spec = (c && typeof c === 'object' && !(c instanceof Node)) ? c : { v: c };
  if (spec.node) {
    // Interactive content: replace only if its signature changed.
    const sig = spec.node.outerHTML;
    if (td.dataset.sig !== sig) {
      td.replaceChildren(spec.node);
      td.dataset.sig = sig;
    }
  } else {
    const v = spec.v === null || spec.v === undefined ? '' : String(spec.v);
    if (td.textContent !== v) td.textContent = v;
    if (td.dataset.sig) delete td.dataset.sig;
  }
  const cls = spec.class || '';
  if (td.className !== cls) td.className = cls;
  const title = spec.title || '';
  if ((td.getAttribute('title') || '') !== title) {
    if (title) td.setAttribute('title', title);
    else td.removeAttribute('title');
  }
}

const pill = (text, kind = '', title = '') =>
  el('span', { class: 'pill ' + kind, title: title || null }, text);

// ---------------------------------------------------------------- tabs

let current = 'live';
let timer = null;

function show(tab) {
  current = tab;
  $$('nav button').forEach((x) => x.classList.toggle('on', x.dataset.tab === tab));
  $$('.tab').forEach((t) => t.classList.toggle('on', t.id === 'tab-' + tab));
  location.hash = tab;
  refreshTab();
  // Only the live view polls hard; the others refresh when you open them.
  clearInterval(timer);
  timer = setInterval(() => { if (current === 'live') refreshLive(); }, 1500);
}

/** Keep the header's connection light honest on every tab, cheaply. */
async function pollStatus() {
  if (current === 'live') return; // refreshLive already does it
  try {
    const s = await api.get('/api/state');
    $('#dot').className = 'dot ' + (s.connected ? 'live' : 'dead');
    $('#conn').textContent = s.connected
      ? `server ok · ${s.last_packet_age}s ago`
      : 'no packets from AC server';
  } catch {
    $('#dot').className = 'dot dead';
    $('#conn').textContent = 'api unreachable';
  }
}
setInterval(pollStatus, 5000);

$$('nav button').forEach((b) => b.addEventListener('click', () => show(b.dataset.tab)));

// ---------------------------------------------------------------- live

function stateCell(d, vsc) {
  if (d.vsc_caller) return pill('CLOSING UP', 'vsc', 'Called the safety car — running with no handicap');
  if (d.vsc_slowed) {
    return pill(`HELD +${d.vsc_extra_ballast}kg`, 'held',
      `Being slowed by the safety car: +${d.vsc_extra_ballast} kg and ` +
      `+${d.vsc_extra_restrictor}% on top of their own handicap`);
  }
  if (!d.loaded) return pill('loading', '', 'Connected but still loading the track');
  if (d.vsc_uses) return pill('SC used', '', 'Has already called their safety car this race');
  return pill('racing', 'ok');
}

async function refreshLive() {
  let s;
  try { s = await api.get('/api/state'); }
  catch { $('#dot').className = 'dot dead'; $('#conn').textContent = 'api unreachable'; return; }

  $('#dot').className = 'dot ' + (s.connected ? 'live' : 'dead');
  $('#conn').textContent = s.connected
    ? `server ok · ${s.last_packet_age}s ago`
    : 'no packets from AC server';

  setText('#s-type', s.session ? s.session.type : '—');
  setText('#s-track', s.session ? s.session.track : '—');
  setText('#s-drivers', s.drivers.length);
  setText('#s-applies', s.session ? (s.session.applies ? 'yes' : 'off') : '—');

  // safety car banner
  const banner = $('#sc-banner');
  if (s.vsc) {
    banner.hidden = false;
    setText('#sc-caller', s.vsc.caller_name);
    setText('#sc-gap', `${s.vsc.gap_s}s`);
    setText('#sc-start', `${s.vsc.start_gap_s}s`);
    setText('#sc-target', `${s.vsc.target_gap_s}s`);
    setText('#sc-eta', s.vsc.eta === null ? '—' : `${Math.round(s.vsc.eta)}s`);
    setText('#sc-remaining', `${Math.round(s.vsc.remaining)}s`);
    $('#sc-fill').style.width = `${s.vsc.closed_pct}%`;
    setText('#sc-pct', `${s.vsc.closed_pct}%`);
  } else {
    banner.hidden = true;
  }

  const rows = s.drivers.map((d, i) => ({
    key: String(d.car_id) + ':' + d.guid,
    cls: d.vsc_caller ? 'is-caller' : d.vsc_slowed ? 'is-held' : '',
    cells: [
      { v: i + 1, class: 'num faint' },
      { v: d.name, class: 'name' },
      { v: d.car_model, class: 'muted faint' },
      { v: d.laps, class: 'num' },
      { v: d.gap_ahead === null ? '—' : `+${d.gap_ahead}`, class: 'num faint',
        title: 'Estimated gap to the car directly ahead, in seconds' },
      { v: ms(d.last_laptime_ms), class: 'num' },
      { v: ms(d.best_laptime_ms), class: 'num' },
      { v: d.ballast, class: 'num' + (d.vsc_slowed ? ' held-val' : '') },
      { v: d.restrictor, class: 'num' + (d.vsc_slowed ? ' held-val' : '') },
      { node: stateCell(d, s.vsc) },
      { node: el('button', {
          class: 'act tiny',
          title: s.vsc
            ? 'A safety car is already running'
            : `Call a safety car for ${d.name} from here, ignoring the usual limits`,
          disabled: !!s.vsc || null,
          onclick: (e) => { e.target.disabled = true; api.post(`/api/vsc/${d.car_id}`).then(refreshLive); },
        }, 'safety car') },
    ],
  }));
  syncTable($('#grid'), rows, 'Nobody on track', 11);

  syncTable($('#log'),
    (s.events || []).map((e, i) => ({
      key: `${e.ts}:${i}`,
      cls: e.level === 'warn' ? 'warn' : '',
      cells: [{ v: clock(e.ts), class: 'faint num' }, { v: e.message }],
    })), 'Nothing yet', 2);
}

function setText(sel, v) {
  const n = $(sel);
  if (n && n.textContent !== String(v)) n.textContent = String(v);
}

$('#btn-recompute').addEventListener('click', async (e) => {
  e.target.disabled = true;
  $('#recompute-msg').textContent = 'fitting…';
  try {
    const r = await api.post('/api/recompute');
    renderFunnel(r);
  } catch { $('#recompute-msg').textContent = 'failed'; }
  e.target.disabled = false;
});

function renderFunnel(r) {
  const f = r.funnel || {};
  $('#recompute-msg').textContent =
    `${f.used ?? r.laps_used} laps used · ${r.drivers_rated} rated · ${r.handicaps_updated} handicaps updated`;

  const wrap = $('#funnel');
  if (!f.total_laps) { wrap.hidden = true; return; }
  wrap.hidden = false;

  const rejected = Object.entries(f.rejected_by_engine || {});
  const lines = [
    ['Laps recorded', f.total_laps, '', 'Every lap the server reported'],
    ...rejected.map(([reason, n]) => [
      '— rejected: ' + reason, n, 'bad',
      REASON_HELP[reason] || REASON_HELP[reason.replace(/^\d+ /, 'N ')] || 'Excluded before the model saw it',
    ]),
    ['Clean laps', f.clean_laps, 'ok', 'Passed every filter'],
    ['— dropped as outliers', f.dropped_outlier, f.dropped_outlier ? 'bad' : '',
      'Slower than the outlier cutoff versus that driver’s own best, so they carry no pace information'],
    ['— dropped by hard trim', f.dropped_trim, f.dropped_trim ? 'bad' : '',
      'Removed by trim_fraction. This is off by default; if it is non-zero you have turned it on'],
    ['— kept but down-weighted', f.downweighted, 'warn',
      'Counted, but worth less than a lap at personal best — this is how traffic is handled without binning the lap'],
    ['Used by the model', f.used, 'ok',
      `Effective weight ${f.effective_weight} once recency and pace weighting are applied`],
  ];

  wrap.replaceChildren(
    el('div', { class: 'funnel-title' }, 'Where every lap went'),
    ...lines.map(([label, n, kind, help]) =>
      el('div', { class: 'funnel-row ' + (kind || ''), title: help },
        el('span', { class: 'fl' }, label),
        el('span', { class: 'fn' }, n ?? 0))),
  );
}

$('#btn-apply').addEventListener('click', async (e) => {
  e.target.disabled = true;
  const r = await api.post('/api/apply');
  $('#recompute-msg').textContent =
    `Re-sent each driver's stored handicap to the server (${r.drivers} on track)`;
  e.target.disabled = false;
});

// ---------------------------------------------------------------- drivers

async function refreshDrivers() {
  const ds = await api.get('/api/drivers');
  syncTable($('#drivers'), ds.map((d) => ({
    key: d.guid,
    cells: [
      { v: d.name, class: 'name' },
      { v: d.pace_pct === null ? '—' : (d.pace_pct > 0 ? '+' : '') + d.pace_pct.toFixed(2) + '%',
        class: 'num',
        title: d.pace_pct === null ? 'Not enough clean laps yet'
          : d.pace_pct < 0 ? 'Quicker than the field average' : 'Slower than the field average' },
      { v: d.skill_n || 0, class: 'num' },
      { node: d.rated ? pill('rated', 'ok', 'Has enough clean laps to be handicapped on measured pace')
                      : pill('provisional', 'warn', 'Still on the field median until they have enough clean laps') },
      { v: ago(d.last_seen), class: 'num faint' },
      { node: el('input', {
          type: 'checkbox', checked: d.enabled ? 'checked' : null,
          title: 'Off = this driver keeps racing but is excluded from the model and gets no handicap',
          onchange: (e) => api.post('/api/drivers/' + encodeURIComponent(d.guid),
            { enabled: e.target.checked }),
        }) },
    ],
  })), 'No drivers seen yet', 6);
}

// ---------------------------------------------------------------- handicaps

let tracksLoaded = false;

async function refreshHandicaps() {
  if (!tracksLoaded) {
    const m = await api.get('/api/model');
    m.tracks.forEach((t) => $('#track-filter').appendChild(el('option', { value: t }, t)));
    tracksLoaded = true;
  }
  const track = $('#track-filter').value;
  const hs = await api.get('/api/handicaps' + (track ? '?track=' + encodeURIComponent(track) : ''));

  const save = (h, patch) => api.post('/api/handicaps', {
    guid: h.guid, track: h.track, car_model: h.car_model,
    restrictor: h.restrictor, ballast: h.ballast, manual: true, ...patch,
  }).then(refreshHandicaps);

  syncTable($('#handicaps'), hs.map((h) => ({
    key: [h.guid, h.track, h.car_model].join('|'),
    cells: [
      { v: h.name || h.guid.slice(0, 10), class: 'name' },
      { v: h.track, class: 'muted' },
      { v: h.car_model, class: 'muted faint' },
      { node: el('input', {
          class: 'mini', type: 'number', step: '5', value: Math.round(h.ballast),
          title: 'Extra weight in kg. Editing pins this row.',
          onchange: (e) => save(h, { ballast: parseFloat(e.target.value) }),
        }), class: 'num' },
      { node: el('input', {
          class: 'mini', type: 'number', step: '1', value: h.restrictor,
          title: 'Air intake restrictor, percent. Editing pins this row.',
          onchange: (e) => save(h, { restrictor: parseFloat(e.target.value) }),
        }), class: 'num' },
      { node: h.manual
          ? pill('pinned', 'warn', 'Set by hand — the model will never overwrite it')
          : pill('auto', '', 'Maintained by the model on every recompute') },
      { node: h.manual
          ? el('button', { class: 'act tiny', title: 'Hand this row back to the model',
              onclick: () => api.del(
                `/api/handicaps/${encodeURIComponent(h.guid)}/${encodeURIComponent(h.track)}/${encodeURIComponent(h.car_model)}`
              ).then(refreshHandicaps) }, 'unpin')
          : el('span', { class: 'faint' }, '') },
    ],
  })), 'No handicaps yet — run a session, then Recompute', 7);
}

$('#track-filter').addEventListener('change', refreshHandicaps);

// ---------------------------------------------------------------- laps

// Each rejection reason gets its own colour and an explanation on hover.
const REASON_STYLE = {
  'out lap':            ['r-outlap',  'Out lap'],
  'contact':            ['r-contact', 'Contact'],
  'safety car':         ['r-sc',      'Safety car'],
  'implausible laptime':['r-bad',     'Bad data'],
  'unknown':            ['r-bad',     'Unknown'],
};
const REASON_HELP = {
  'out lap': 'First flying lap after joining or leaving the pits — not representative, so it is excluded',
  'contact': 'A collision happened within the contact cooldown, so the lap time is meaningless',
  'safety car': 'Run during a safety car phase, when nobody’s pace reflects their real speed',
  'implausible laptime': 'Zero, negative or absurdly long — bad data from the server',
  'N cut(s)': 'The driver cut the track, so the lap is faster than a clean one would be',
};

function reasonCell(l) {
  if (l.clean) return { node: pill('counted', 'ok', 'Used by the model') };
  const raw = l.reason || 'unknown';
  const cutMatch = /^(\d+) cut/.exec(raw);
  if (cutMatch) {
    return { node: pill(`${cutMatch[1]} cut${cutMatch[1] === '1' ? '' : 's'}`, 'r-cut',
      REASON_HELP['N cut(s)']) };
  }
  const [cls, label] = REASON_STYLE[raw] || ['r-bad', raw];
  return { node: pill(label, cls, REASON_HELP[raw] || raw) };
}

let lapFilter = '';

async function refreshLaps() {
  const ls = await api.get('/api/laps?limit=300');
  const counts = { counted: 0 };
  for (const l of ls) {
    const k = l.clean ? 'counted' : (/^\d+ cut/.test(l.reason || '') ? 'cuts' : (l.reason || 'unknown'));
    counts[k] = (counts[k] || 0) + 1;
  }

  // legend doubles as a filter
  const legend = $('#lap-legend');
  const chips = [['', 'all', ls.length], ['counted', 'counted', counts.counted || 0],
    ['cuts', 'cuts', counts.cuts || 0], ['out lap', 'out lap', counts['out lap'] || 0],
    ['contact', 'contact', counts.contact || 0], ['safety car', 'safety car', counts['safety car'] || 0]];
  legend.replaceChildren(...chips.filter(([, , n], i) => i < 2 || n > 0).map(([val, label, n]) =>
    el('button', {
      class: 'chip ' + (lapFilter === val ? 'on ' : '') +
        (val === 'counted' ? 'ok' : val === 'cuts' ? 'r-cut'
          : val === 'out lap' ? 'r-outlap' : val === 'contact' ? 'r-contact'
          : val === 'safety car' ? 'r-sc' : ''),
      onclick: () => { lapFilter = val; refreshLaps(); },
    }, `${label} ${n}`)));

  const shown = ls.filter((l) => {
    if (!lapFilter) return true;
    if (lapFilter === 'counted') return l.clean;
    if (lapFilter === 'cuts') return !l.clean && /^\d+ cut/.test(l.reason || '');
    return !l.clean && l.reason === lapFilter;
  });

  syncTable($('#laps'), shown.map((l) => ({
    key: String(l.id),
    cls: l.clean ? '' : 'rejected',
    cells: [
      { v: clock(l.ts), class: 'faint num' },
      { v: l.name || l.guid.slice(0, 10), class: 'name' },
      { v: l.track, class: 'muted' },
      { v: l.car_model, class: 'muted faint' },
      { v: ms(l.laptime_ms), class: 'num' },
      { v: Math.round(l.ballast), class: 'num faint' },
      { v: l.restrictor, class: 'num faint' },
      reasonCell(l),
    ],
  })), 'No laps recorded yet', 8);
}

// ---------------------------------------------------------------- model

async function refreshModel() {
  const m = await api.get('/api/model');

  syncTable($('#trackcar'), m.track_car.map((t) => ({
    key: t.track + '|' + t.car_model,
    cells: [
      { v: t.track }, { v: t.car_model, class: 'muted faint' },
      { v: t.base_log ? ms(Math.exp(t.base_log)) : '—', class: 'num' },
      { v: t.samples, class: 'num faint' },
    ],
  })), 'Nothing fitted yet', 4);

  syncTable($('#sens'), m.sensitivity.map((s) => ({
    key: s.track + '|' + s.car_model,
    cells: [
      { v: s.car_model },
      s.track ? { v: s.track, class: 'muted' }
              : { node: pill('all tracks', '', 'Car-wide average that a new track starts from') },
      { v: (s.k_restrictor * 100).toFixed(3) + '%', class: 'num' },
      { v: (s.k_ballast * 100).toFixed(3) + '%', class: 'num' },
      { v: s.samples, class: 'num faint' },
    ],
  })), 'Nothing fitted yet', 5);

  syncTable($('#affinity'), (m.affinity || []).map((a) => ({
    key: a.guid + '|' + a.track,
    cells: [
      { v: a.name || a.guid.slice(0, 10), class: 'name' },
      { v: a.track, class: 'muted' },
      { v: (a.value > 0 ? '+' : '') + (a.value * 100).toFixed(2) + '%', class: 'num',
        title: a.value < 0 ? 'Goes better here than their general level'
                           : 'Goes worse here than their general level' },
      { v: a.samples, class: 'num faint' },
    ],
  })), 'No track-specific pattern found yet', 4);

  const ss = await api.get('/api/sessions');
  syncTable($('#sessions'), ss.map((s) => ({
    key: String(s.id),
    cells: [
      { v: new Date(s.started * 1000).toLocaleString(), class: 'faint' },
      { v: s.track }, { v: s.session_type, class: 'muted' },
      { v: s.clean_laps, class: 'num' },
    ],
  })), 'No sessions yet', 4);
}

// ---------------------------------------------------------------- settings

// [key, label, what it does, what happens when you change it]
const GROUPS = [
  ['Handicap shape', [
    ['restrictor_share', 'Restrictor share',
      'How the handicap is split between the two tools. 0.6 delivers 60% of the slowdown as restrictor and 40% as ballast.',
      'Higher = more restrictor, which only costs time on straights and corner exit. Lower = more ballast, which also hurts braking and tyre wear, so it bites more over a long run.'],
    ['max_restrictor', 'Max restrictor (%)',
      'Ceiling on the air intake restrictor for a normal handicap.',
      'Past about 25% the cars get unpleasant — flat spots in the powerband and the wrong gearing.'],
    ['max_ballast', 'Max ballast (kg)',
      'Ceiling on added weight for a normal handicap.',
      'Raise it if your quickest driver still walks away. 120 kg is roughly 5-6% of lap time on a typical car.'],
    ['floor_restrictor', 'Floor restrictor (%)',
      'Everyone carries at least this much, even a driver with no handicap at all.',
      'This is what gives the safety car room to give something back. Set to 0 and the catch-up has nothing to remove.'],
    ['floor_ballast', 'Floor ballast (kg)',
      'The matching weight floor that every driver carries.',
      'Same reason as the restrictor floor: headroom for the safety car.'],
    ['target_percentile', 'Target quantile',
      'Which driver the field is levelled down to, as a quantile of pace. 1.0 is the very slowest driver, 0.0 the fastest.',
      'Higher = everyone slowed toward the slowest driver, so bigger handicaps all round. 0.85 leans slow but ignores one extreme outlier.'],
  ]],
  ['Convergence', [
    ['damping', 'Damping',
      'How much of each newly computed change is actually applied.',
      'Lower = handicaps move gently and take more races to settle. Higher = they react fast but can lurch on a single off night.'],
    ['max_restrictor_step', 'Max restrictor step (%)',
      'The most the restrictor may move in one recompute.',
      'Lower keeps changes predictable between races.'],
    ['max_ballast_step', 'Max ballast step (kg)',
      'The most the ballast may move in one recompute.',
      'Lower keeps changes predictable between races.'],
    ['min_laps_for_rating', 'Min clean laps to rate',
      'How many clean laps a driver needs before they are handicapped on measured pace.',
      'Until then they get the field median. Higher is more cautious but keeps newcomers unrated for longer.'],
    ['half_life_days', 'Lap half-life (days)',
      'How quickly old laps lose influence. At 60 days, a lap from two months ago counts half as much as one from today.',
      'Lower = the model follows recent form closely, so an improving driver is caught faster. Higher = steadier but slower to notice someone has got quicker.'],
    ['recompute_after_session', 'Refit after each session',
      'Refit the model automatically when a session ends.',
      'Off means handicaps only change when you press Recompute.'],
  ]],
  ['Which laps count', [
    ['drop_cut_laps', 'Reject cut laps',
      'Throw away any lap the server flagged as having cut the track.',
      'Should normally stay on — a cut lap is faster than a clean one, so it would make the driver look quicker than they are.'],
    ['collision_cooldown_s', 'Contact cooldown (s)',
      'Ignore a lap if a collision happened within this many seconds of it.',
      'Higher throws away more laps but is stricter about contaminated ones.'],
    ['outlier_ratio', 'Outlier cutoff',
      'Drop a lap outright if it is slower than this multiple of that driver’s best on the same track and car. 1.20 means 20% off their best.',
      'These laps carry no pace information — a spin, a trip through the gravel. Lower is stricter; too low and ordinary traffic laps get binned.'],
    ['pace_weight_falloff', 'Pace weight falloff',
      'How fast a lap loses weight as it gets slower than that driver’s best. 0.02 means a lap 2% off counts half, 4% off counts a quarter.',
      'This is how traffic is handled without discarding the lap. Lower = only near-perfect laps matter. Set 0 to weight every usable lap equally.'],
    ['trim_fraction', 'Hard trim fraction',
      'Optionally keep only the quickest fraction of each driver’s laps. 1.0 means keep everything.',
      'Leave at 1.0. The pace weighting above does the same job without throwing information away — an earlier version trimmed to 0.5 and silently binned half the data.'],
  ]],
  ['Safety car', [
    ['vsc_enabled', 'Enabled',
      'Whether drivers can call a safety car at all.', ''],
    ['vsc_command', 'Chat command',
      'What a driver types in chat to call one.',
      'Keep the leading "!" — a "/" prefix would be eaten by the server as an unknown admin command.'],
    ['vsc_max_slowdown', 'Hold strength',
      'How much slower the held cars are made to run, as a fraction of their own pace. 0.6 means they lap 60% slower.',
      'This is the main lever on how fast the field comes back together: 0.6 closes about 0.37s of gap per second of running, so a 20s gap takes roughly 50s. Higher closes faster but the held cars become horrible to drive.'],
    ['vsc_target_gap_s', 'End when gap under (s)',
      'The phase ends as soon as the caller is this close to the car ahead.',
      'Lower means the caller is brought right onto the back of the car ahead; higher ends it sooner.'],
    ['vsc_max_duration_s', 'Hard time limit (s)',
      'The phase always ends after this long, even if the gap never closed.',
      'A safety net for the case where the caller is so far back the gap cannot be closed.'],
    ['vsc_min_gap_s', 'Min gap to call (s)',
      'A driver must be at least this far behind the car ahead to call one.',
      'This is what stops it being used as push-to-pass in a close fight.'],
    ['vsc_min_lap', 'Earliest lap',
      'No safety car before this lap.',
      'Stops someone calling one before the field has settled.'],
    ['vsc_per_session', 'Calls per driver per race',
      'How many times each driver may call one in a race.', ''],
    ['vsc_forbid_final_lap', 'Block on final lap',
      'Refuse a call on the last lap.',
      'Off would let someone rewrite the result at the flag.'],
    ['vsc_race_only', 'Race sessions only',
      'Refuse calls in practice and qualifying.', ''],
    ['vsc_compress_pack', 'Bunch the whole pack',
      'Grade the hold by gap, so cars further ahead are held harder and the leaders bunch together too.',
      'More like a real safety car, but the caller closes more slowly because the car directly ahead of them is held less. Off gives the caller the fastest possible catch-up.'],
    ['vsc_slow_whole_field', 'Also hold cars behind',
      'Hold drivers who are behind the caller as well.',
      'Keeps the order behind the caller intact rather than letting them through. Off leaves those drivers alone.'],
    ['vsc_ramp_s', 'Ease in/out (s)',
      'Spread the penalty change over this long at the start and end of a phase.',
      'Stops a driver being hit with hundreds of kilos between one corner and the next.'],
    ['vsc_tick_s', 'Recalculation interval (s)',
      'How often gaps are re-measured and the hold recomputed.',
      'Lower reacts faster but sends more admin commands, each of which pops a notification for the affected driver.'],
    ['vsc_max_extra_restrictor', 'Max extra restrictor (%)',
      'Ceiling on the restrictor the safety car may add on top of a driver’s own handicap.',
      'AC’s own limit is 100%.'],
    ['vsc_max_extra_ballast', 'Max extra ballast (kg)',
      'Ceiling on the weight the safety car may add on top of a driver’s own handicap.',
      'AC’s own limit is 5000 kg. 2500 kg with full restrictor is roughly half pace.'],
  ]],
  ['Application', [
    ['apply_in_practice', 'Apply in practice', 'Hand out handicaps during practice sessions.',
      'Leaving this on means practice laps are recorded with a handicap, which the model accounts for.'],
    ['apply_in_qualify', 'Apply in qualifying', 'Hand out handicaps during qualifying.',
      'Off means qualifying is a free-for-all and the grid reflects raw pace.'],
    ['apply_in_race', 'Apply in race', 'Hand out handicaps during races.', ''],
    ['announce_handicaps', 'Tell drivers their handicap',
      'Whisper each driver their ballast and restrictor as they load in.',
      'Off keeps it quiet, but people generally want to know what they are carrying.'],
    ['deadband_restrictor', 'Restrictor deadband (%)',
      'Do not re-send a restrictor command unless the value moved at least this much.',
      'Every admin command pops a notification for that driver, so this keeps the spam down.'],
    ['deadband_ballast', 'Ballast deadband (kg)',
      'Do not re-send a ballast command unless the value moved at least this much.',
      'Same reason as the restrictor deadband.'],
  ]],
  ['Model priors', [
    ['prior_k_restrictor', 'Starting cost per 1% restrictor',
      'Initial guess for how much lap time 1% of restrictor costs, as a fraction. 0.002 is 0.2%.',
      'Only matters before the model has learned the real figure from your own data.'],
    ['prior_k_ballast', 'Starting cost per 10 kg',
      'Initial guess for how much lap time 10 kg costs, as a fraction.',
      'Only matters before the model has learned the real figure.'],
    ['sensitivity_prior_weight', 'Prior strength',
      'How many imaginary laps the starting guess is worth when fitting the real figure.',
      'Higher keeps the learned sensitivity close to the guess, which is safer on thin data.'],
    ['track_sensitivity_weight', 'Per-track prior strength',
      'How strongly a track’s own sensitivity is pulled toward its car-wide average.',
      'Lower lets tracks diverge from one another faster, which is what makes a power circuit differ from a tight one.'],
    ['affinity_prior_weight', 'Affinity prior strength',
      'How hard the driver-by-track term is shrunk toward zero.',
      'Higher suppresses it; set it very high to switch off track affinity entirely.'],
    ['max_affinity', 'Max affinity',
      'Cap on the driver-by-track offset, as a fraction of lap time. 0.015 is 1.5%.', ''],
  ]],
  ['Connection — needs a restart', [
    ['listen_host', 'Plugin listen host',
      'The address acbop listens on. Must match UDP_PLUGIN_ADDRESS in server_cfg.ini.', ''],
    ['listen_port', 'Plugin listen port',
      'The port acbop listens on. Must match the port in UDP_PLUGIN_ADDRESS.', ''],
    ['server_host', 'AC server host',
      'Where the AC server is. Usually the same machine.', ''],
    ['server_port', 'AC server port',
      'Must match UDP_PLUGIN_LOCAL_PORT in server_cfg.ini.', ''],
    ['realtime_interval_ms', 'Car update interval (ms)',
      'How often the server reports car positions.',
      'Lower gives more accurate gaps for the safety car at the cost of more traffic.'],
    ['web_port', 'Web port', 'Port this interface is served on.', ''],
  ]],
];

let cfgCache = {};

async function refreshSettings() {
  cfgCache = await api.get('/api/config');
  const wrap = $('#settings');
  wrap.replaceChildren();
  for (const [title, items] of GROUPS) {
    const g = el('div', { class: 'group' }, el('h3', {}, title));
    for (const [key, label, what, effect] of items) {
      const val = cfgCache[key];
      if (val === undefined) continue;
      const tip = effect ? `${what}\n\n${effect}` : what;
      const input = typeof val === 'boolean'
        ? el('input', { type: 'checkbox', 'data-key': key, checked: val ? 'checked' : null })
        : el('input', {
            type: typeof val === 'number' ? 'number' : 'text',
            class: 'mini', step: 'any', 'data-key': key, value: String(val),
          });
      input.title = tip;
      g.appendChild(el('div', { class: 'field', title: tip },
        el('label', {},
          el('span', { class: 'flabel' }, label,
            el('i', { class: 'help', title: tip }, '?')),
          el('span', { class: 'hint' }, what)),
        input));
    }
    wrap.appendChild(g);
  }
}

$('#btn-save').addEventListener('click', async () => {
  const patch = {};
  $$('#settings input').forEach((i) => {
    patch[i.dataset.key] = i.type === 'checkbox' ? i.checked : i.value;
  });
  const r = await api.post('/api/config', patch);
  cfgCache = r.config;
  $('#save-msg').textContent = r.changed.length
    ? `saved: ${r.changed.join(', ')}` : 'no changes';
  setTimeout(() => { $('#save-msg').textContent = ''; }, 5000);
});

$('#btn-reset').addEventListener('click', refreshSettings);

$('#btn-sc-end').addEventListener('click', async (e) => {
  e.target.disabled = true;
  try { await api.del('/api/vsc'); } finally { e.target.disabled = false; }
  refreshLive();
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

const initial = (location.hash || '#live').slice(1);
show($$('nav button').some((b) => b.dataset.tab === initial) ? initial : 'live');
pollStatus();
