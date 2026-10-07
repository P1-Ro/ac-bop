# acbop — adaptive balance of performance for Assetto Corsa

A server-side plugin that learns how quick each driver is and hands out ballast and
restrictor so a mixed-ability group races together. Plus a once-per-race catch-up
boost for anyone who gets dropped.

Nothing is installed on any client. Drivers join normally.

- Handicaps are keyed on **Steam GUID**, so join order and car slot are irrelevant.
- A driver who has **never run a track** still gets a sensible number, because their
  pace is estimated across every track and car they have ever driven.
- Handicaps **vary by track and car**, learned from lap times rather than configured.
- Everything is visible and overridable in a web GUI.

---

## How it works

### The model

Lap times are factorised:

```
log(laptime) = base[track, car] + skill[driver] + affinity[driver, track] + handicap_effect
```

- `skill` — one number per driver, estimated from every lap they have ever run. This is
  what transfers to a track they have never seen.
- `base` — the reference pace of a track/car, estimated from everyone else's laps. It
  exists before a newcomer turns a wheel.
- `affinity` — a driver's pace at one specific circuit beyond their general level.
  Shrunk hard toward zero, so a one-off good night does not move it.
- `handicap_effect` — `log(1 + kr·restrictor + kb·ballast/10)`, with `kr` and `kb`
  learned **per track and car**: a restrictor is worth a lot at Monza and very little
  somewhere tight and slow.

It is fit by alternating weighted means — no numpy, no matrix inversion, converges in a
few passes on any realistic amount of data.

### Turning pace into a handicap

Target pace is a quantile of the field (`target_percentile`, default 0.85 — leaning
slow but ignoring one extreme outlier). For each driver:

```
gap   = exp(target − effective_skill) − 1      # fractional lap time to add
r     = gap × restrictor_share / kr
b     = gap × (1 − restrictor_share) / kb × 10
```

`restrictor_share` defaults to **0.6**, so 60% of the handicap is delivered as
restrictor and 40% as ballast. The split matters: restrictor only costs you on
straights and corner exit, while ballast also hits braking and tyre wear, which is what
makes a long run competitive rather than just a qualifying lap. If one channel hits its
cap, the remainder spills into the other.

### Stability

- Applied at session start and **held for the whole race**, so you are not chasing a
  moving target mid-stint.
- Damped (`damping`, default 0.4) and step-clamped, so handicaps converge over three or
  four races rather than lurching.
- Old laps decay with a 60-day half-life, so improving drivers are not held back by
  last season's pace.

### Lap filtering

A lap only counts if it has no cuts, is not an out-lap, had no contact within 20 s, is
inside `outlier_ratio` of that driver's personal best on the combination, and was not
run under a catch-up boost. Then only the quickest `trim_fraction` of their laps are
used, which kills traffic contamination.

### The catch-up

Vanilla acServer has no safety car and no speed limiter, so a true VSC is not reachable
without CSP on clients. Instead everyone carries a **floor** (default 6% / 25 kg), which
leaves headroom to go *down*. Typing `!vsc` drops the caller to zero handicap for 45
seconds — a real boost rather than a punishment for everyone else.

Refused if: they are leading, the car ahead is closer than `vsc_min_gap_s` (stops it
becoming push-to-pass in a close fight), it is lap 1 or the final lap, they have already
used it this race, or the session is not a race. Laps run under it never reach the model.

Other chat commands: `!bop` shows your current handicap, `!help` lists them.

---

## Install

Needs Python 3.10+ on the machine running the AC server.

```bash
pip install -r requirements.txt
python3 run.py            # writes config.json on first run, then edit it
```

In `cfg/server_cfg.ini`:

```ini
[SERVER]
UDP_PLUGIN_ADDRESS=127.0.0.1:12000   ; where acbop listens
UDP_PLUGIN_LOCAL_PORT=11000          ; where the AC server listens
```

Matching `config.json`:

```json
{
  "listen_port": 12000,
  "server_port": 11000,
  "web_port": 8770,
  "web_password": "something"
}
```

Then open `http://<server>:8770`. Leave `web_password` empty only on a LAN or VPN.

Create the `results/` directory next to `acServer` if it does not exist — without it the
server silently drops `LAP_COMPLETED` events, which is a long-standing AC bug and would
mean acbop never sees a lap.

### systemd

```ini
[Unit]
Description=acbop
After=network.target

[Service]
WorkingDirectory=/opt/acbop
ExecStart=/usr/bin/python3 /opt/acbop/run.py -c /opt/acbop/config.json
Restart=always
User=acserver

[Install]
WantedBy=multi-user.target
```

### If you already run another plugin

Vanilla acServer supports **one** UDP plugin. If stracker, KissMyRank or a server
manager already holds the port, chain them with a relay (ACSRelay, or
`germanrcuriel/assetto-corsa-server-udp2ws`) and point acbop at the relay. Most server
managers have a plugin-chain config for exactly this.

---

## Try it without Assetto Corsa

`demo.py` impersonates an AC server and races a fake field against acbop, so you can
see the GUI working before wiring anything up.

```bash
python3 run.py      # terminal 1, leave running
python3 demo.py     # terminal 2
```

Five rounds of three races across circuits with deliberately different character, then
it leaves a grid on track with one driver mid catch-up. Open the GUI and look at the
Handicaps and Model tabs. `python3 demo.py -r 10` for a longer run; delete
`data/acbop.sqlite` to start clean.

Demo mode binds the port a real AC server would use, so stop one before running the
other.

## Running it for the first time

1. Start acbop, run a normal practice session, let everyone put in 10+ laps.
2. Hit **Recompute now**. Drivers with enough clean laps flip from provisional to rated.
3. Race. Handicaps are applied as each driver loads in.
4. The model refits after every session automatically.

Expect roughly three or four races before the numbers settle. Until a driver is rated
they get the field median — not zero (a quick newcomer would walk it) and not the
maximum (unfair to a slow one).

---

## The GUI

- **Live** — grid with lap times, current ballast and restrictor, catch-up state.
  Recompute and re-apply on demand; `boost` grants a catch-up manually.
- **Drivers** — pace relative to the field with the handicap removed. Toggle anyone out
  of the system entirely.
- **Handicaps** — every driver × track × car. Edit a number to **pin** it; pinned rows
  are never auto-updated until you unpin.
- **Laps** — every lap recorded, including rejected ones and why.
- **Model** — reference lap times, learned per-track sensitivity, driver/track affinity.
- **Settings** — everything, with explanations. Connection settings need a restart.

---

## Tests

```bash
python3 tests/test_convergence.py       # does the field actually converge
python3 tests/test_vsc.py               # catch-up: grant, expiry, every refusal path
python3 tests/test_track_variation.py   # per-track sensitivity and driver affinity
```

These spin up a fake AC server that speaks ACSP over a real UDP socket and drive the
whole stack. The packet encoders in `tests/simserver.py` are written independently of
the decoders in `acbop/protocol.py`, so a disagreement between them shows up as a test
failure rather than a silent bug on race night.

Representative result — six drivers spread across 7.8% of lap time:

```
race   spread%  P1-last%   handicaps (kg/%)
 raw     2.371      7.79
   1     0.707      2.11   Alien:120/25 Quick:120/20 ... Slow:25/6
   8     0.724      2.17   Alien:120/25 Quick:102/17 ... Slow:25/6
```

---

## Things worth knowing

**You cannot fully equalise an extreme spread.** 25% restrictor and 120 kg is about 8%
of lap time on a typical car. If your quickest driver is 8% faster than your slowest,
they will stay ahead and the handicap simply saturates. Raise the caps if you want, but
past roughly 25% restrictor the cars get genuinely unpleasant — flat spots in the
powerband, wrong gearing — and people stop enjoying it. Narrowing `target_percentile`
is usually the better lever.

**The split between `kr` and `kb` is only weakly identified.** acbop always applies
ballast and restrictor together in a fixed ratio, so the two coefficients are collinear
and the fit cannot cleanly separate them; the ridge prior is what keeps it stable. Their
*combined* effect is estimated well, and the feedback loop closes regardless — if `kr`
is underestimated the driver is over-handicapped, the next refit sees them slower, and
it backs off. So treat the per-channel numbers on the Model tab as indicative rather
than physical measurements.

**Affinity is deliberately conservative.** With a simulated ±1.2% true track bias it
recovers about ±0.5%. That is the shrinkage doing its job — with six drivers and a few
races, a looser prior would mostly fit noise. It grows toward the truth as data
accumulates. Raise `affinity_prior_weight` to suppress it further, or set it very high
to disable the term.

**Admin penalties pop a notification** for the affected driver. The deadband settings
stop acbop resending unchanged values, which keeps this to once per session per driver
in normal running.

**Pit detection is approximate.** ACSP gives no pit event, so a sustained stop is
treated as "the next lap is an out-lap". A driver who parks on track and rejoins loses
one lap of data. Harmless.

**Restrictor behaviour mid-session is worth verifying on your own server** before you
build a league around it — check with a manual `/restrictor <car_id> 20` that it applies
immediately rather than at the next pit stop.

---

MIT.
