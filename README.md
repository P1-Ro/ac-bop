# acbop — adaptive balance of performance for Assetto Corsa

A server-side plugin that learns how quick each driver is and hands out ballast and
restrictor so a mixed-ability group races together. Plus a once-per-race virtual safety
car for anyone who gets dropped: the cars ahead are speed-limited until they catch up.

Drivers install nothing by hand. The safety car's speed limiter is a small CSP script the
server pushes to every player's game; the only requirement is CSP, which most players
already run. An optional [acbop HUD](#the-acbop-hud) shows everyone's ballast and
restrictor on the leaderboard and puts the safety car on a button.

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

### Which laps count

A lap is excluded outright if it has cuts, is an out-lap, had contact within 20 s, or
was run during a safety car phase. Each reason gets its own colour on the Laps tab and
the rejected laps are kept on purpose, so you can always see why the model ignored one.

### Lap weighting

Nothing clean is thrown away. Each lap carries two multiplied weights:

- **recency** — exponential decay, 60-day half-life by default
- **pace** — a lap at that driver's personal best on the combination weighs 1.0, and
  every 2% of lap time above it halves the weight

That second one is how traffic and lifting are handled *without* discarding the lap. A
hard cut still applies for laps so slow they carry no pace information at all (20% off
a personal best by default — a spin, a trip through the gravel).

The optional `trim_fraction` hard trim is **off** by default. An earlier version set it
to 0.5, which silently binned half of every driver's clean laps; the Live tab now shows
a funnel accounting for every single recorded lap so nothing can go missing quietly.

### The safety car

Vanilla acServer has no safety car and no speed limiter, and the plugin protocol cannot
set one: the only levers a server plugin has are `/ballast` and `/restrictor`. So there
are two ways to hold the cars ahead, chosen with `vsc_mode`:

- **`limiter`** (default): a real speed cap, like a pit limiter. acbop serves a small
  CSP script that the server pushes to every player's game, and that script holds the
  car at `vsc_speed_limit_kmh` while it is being held. See
  [In-game limiter](#in-game-limiter-csp) for the one-line server setup. A car that
  plainly is not being limited (no CSP, script missing) is caught after a grace period
  and held with the restrictor instead.
- **`restrictor`**: no client setup at all. The restrictor alone is used as a pace
  limiter, described below. It never adds ballast, but a vanilla server caps it at 100%,
  which is only worth about 20% of lap time, so it closes gaps several times more slowly.

Everyone carries a **floor** (default 6% / 25 kg), which leaves headroom to go *down*:
the caller drops it.

Typing `!vsc` (or pressing the bound button in the acbop HUD) starts a live phase:

- the **caller** runs with no handicap at all
- every car **ahead** is held: capped at `vsc_speed_limit_kmh` in limiter mode, or in
  restrictor mode limited to the same target lap time, the caller's own unhandicapped
  pace × (1 + `vsc_max_slowdown`)
- gaps are re-measured every second and the whole thing is recomputed from live
  positions
- it ends once the caller has stayed within `vsc_target_gap_s` of the car ahead for two
  seconds, or at the hard time limit (`vsc_max_duration_s`, default 180 s)

Refused if: they are leading, the car ahead is closer than `vsc_min_gap_s` (stops it
becoming push-to-pass in a close fight), it is lap 1 or the final lap, they have already
used it this race, one is already running, or the session is not a race. Every lap run
during a phase is excluded from the model, and the lap after it ends is treated as an
out-lap.

Gaps and race order come from live positions. A car crossing the line is counted once,
whichever of the lap event and the position update arrives first, so a caller crossing
the line is never mistaken for the new leader.

Other chat commands: `!bop` shows your handicap, `!gap` the gap ahead, `!help` lists them.

#### Limiter mode

Held cars are capped at `vsc_speed_limit_kmh` (default 100 km/h) by the
[in-game limiter](#in-game-limiter-csp). Corners slower than the cap are unaffected, so the
caller gains mostly on the straights; in the test, a 22-second gap closed in 37 seconds.
The banner's ETA is measured from the gap actually closed so far, since a speed cap has
no formula for it.

The safety net: a held car still more than `vsc_limiter_tolerance_kmh` (15) over the cap
after `vsc_limiter_grace_s` (10 s), for three seconds running, evidently has no script.
It is held at 100% restrictor for the rest of the phase, told why in chat, and flagged on
the Live tab.

#### Restrictor mode

**The restrictor is set per driver, from their pace.** A quick driver needs more
restrictor than a slow one to reach the same target. Each held car's starting value
comes from that driver's own lap time and the model's learned per-track sensitivity.
After that, a live correction compares their measured pace with the target every tick
and nudges the restrictor until they match. The correction matters because a restrictor
bites less than linearly at high values, so the model's estimate alone under-delivers.
Once the quickest car is at the ceiling, what it actually measures replaces the
estimate, and that becomes the pace the whole group is held to. In the test every held
car settles within 0.1% of the target pace.

Pace is measured against **each driver's own lap profile**, recorded from their last
clean lap: how much of their lap time goes into each part of the circuit. Without it, a
car in a slow hairpin would look as if it had been slowed too hard, and one on a long
straight as not slowed enough, so the restrictor would swing every few seconds. The same
profile turns gaps into real seconds rather than track distance, which is why the
closure rate and ETA hold steady through a lap.

The closure rate is **physics, not a guess**. If a held car runs at (1 + s) times the
caller's lap time, the caller gains `s/(1+s)` seconds per second of running. With the
restrictor capped at 100% on a vanilla server, `s` is usually around 0.2, which gives
about 0.17 s/s, so a 20-second gap takes roughly 100 seconds. `vsc_max_slowdown` is an
upper bound on `s`; the quickest held car at full restrictor normally sets it.

An earlier version did this with ballast, adding up to 2.5 tonnes. It worked, but the
held cars wallowed, understeered and braked like lorries. A restrictor only takes away
power, so the cars still turn and stop normally.

How hard each car is held:

- **default** — every car at or beyond the gap the caller must close is held as hard as
  allowed, giving the fastest possible catch-up
- **`vsc_compress_pack`** — grade the hold by gap so the leaders bunch up too, more like
  a real safety car, at the cost of the caller closing more slowly

### In-game limiter (CSP)

During an online race CSP only lets a **server-provided** script touch a car's throttle
and brakes; an app a player installs may not. So the limiter is an online script, served
by acbop and pushed by the server to every player. Add this to the server's
`cfg/csp_extra_options.ini` (or the CSP extra options box in Content Manager's server
settings), with the address players can reach acbop's web port on:

```ini
[SCRIPT_1]
SCRIPT = 'http://your.server.address:8770/csp/vsc.lua?car={SessionID}'
REQUIRED = 1
```

`{SessionID}` is filled in by the game with the player's slot, which is how the script
knows which car it is. `REQUIRED = 1` stops anyone joining without it. The web port has to
be open to players, but only `/csp/` is reachable without the GUI password: the script
itself, and `/csp/state`, a read-only list of who is held plus every car's ballast and
restrictor, nothing players cannot already see in-game.

While a car is held, the script lifts the throttle as it approaches the cap and adds a
gentle brake (at most 35%) only well past it. The cap closes in from the car's own
speed at 12 km/h per second, so nobody is slammed down from top speed. It never adds
throttle the driver is not asking for, and never touches the caller or the cars behind
them. A yellow "VIRTUAL SAFETY CAR" banner tells each driver the limit, or tells the
caller to catch up. If acbop stops answering for a few seconds, the script lets go.

Using the CSP physics functions marks the lap invalid, which is fine: laps under a safety
car are excluded anyway.

### The acbop HUD

A small CSP app in [`hud/`](hud/): the leaderboard from CMRT Essential HUD by CMRT Group,
cut down to just that, and installed as its own `acbop-HUD` app so it sits alongside a
full CMRT install rather than replacing it. Everything else from CMRT (its other apps,
the deltabar, logos, intro animations, fonts and images the leaderboard does not use) is
gone; the deltabar's lap recording, which the leaderboard needs for intervals, is
replaced by a small recorder of our own. It adds two things for drivers:

- The **leaderboard** shows each driver's ballast and restrictor, from acbop, next to
  their name. While a safety car runs, held cars are shown in yellow, the caller in
  green, and the flag area reads VIRTUAL SAFETY CAR.
- A **rebindable button** calls a safety car (Settings → Safety car tab: click the box,
  then press any key or wheel button). It sends the same chat command, so every rule
  above still applies.

The HUD finds acbop from the `[SCRIPT_...]` line above, or from an explicit entry in
`csp_extra_options.ini`; failing both, type the address in the Safety car tab:

```ini
[ACBOP]
URL = 'http://your.server.address:8770'
```

The HUD only displays and asks. The limiting is done by the online script, so a driver
without the HUD is still held.

Drivers install it like any CSP app: download the zip from the
[latest release](https://github.com/P1-Ro/ac-bop/releases/latest) and drop it on Content
Manager, or copy its `assettocorsa` folder over the game's. To build the zip yourself:

```bash
python3 tools/build_hud_zip.py     # -> dist/acbop_hud_v<version>.zip
```

In-game it has two windows, **acbop leaderboard** and **acbop settings** (tabs:
Leaderboard, Safety car). Files in `hud/` keep CMRT's Windows line endings
(`.gitattributes` stops git converting them).

### Recompute vs Re-apply

Two buttons on the Live tab that do different things:

- **Recompute now** refits the pace model from every recorded lap and rewrites all
  stored handicaps. It does not touch cars already on track.
- **Re-apply to grid** re-sends each driver on track the handicap currently stored for
  them, without refitting anything. Use it after editing a value by hand, or if a car's
  penalty looks out of step with what the Handicaps tab says.

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

For the safety car's speed limiter, also add the script line from
[In-game limiter](#in-game-limiter-csp) to `cfg/csp_extra_options.ini` and open the web
port to players. Skip it and the safety car still works, held with the restrictor after a
grace period; or set `vsc_mode` to `restrictor` in the Settings tab to use that from the
start.

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
other. There are no game clients in the demo, so nothing runs the in-game limiter: after
the grace period the safety net holds those cars with the restrictor, shown as
RESTRICTED on the Live tab.

## Running it for the first time

1. Add the [in-game limiter](#in-game-limiter-csp) line to `csp_extra_options.ini`, and
   point drivers at the [HUD](#the-acbop-hud) if they want it.
2. Start acbop, run a normal practice session, let everyone put in 10+ laps.
3. Hit **Recompute now**. Drivers with enough clean laps flip from provisional to rated.
4. Race. Handicaps are applied as each driver loads in.
5. The model refits after every session automatically.

Expect roughly three or four races before the numbers settle. Until a driver is rated
they get the field median — not zero (a quick newcomer would walk it) and not the
maximum (unfair to a slow one).

---

## The GUI

- **Live** — grid with lap times, gaps, current ballast and restrictor, and safety car
  state: the caller, cars LIMITED by the in-game limiter, and any RESTRICTED by the
  safety net. A live banner tracks a running phase with a closure bar and an ETA, and can
  end it early. Recompute and re-apply on demand; `safety car` starts a phase manually,
  ignoring the per-race budget. After a recompute, a funnel accounts for every recorded
  lap — nothing is dropped without being shown.
- **Drivers** — pace relative to the field with the handicap removed. Toggle anyone out
  of the system entirely.
- **Handicaps** — every driver × track × car. Edit a number to **pin** it; pinned rows
  are never auto-updated until you unpin.
- **Laps** — every lap recorded, with each rejection reason in its own colour. Click a
  colour to filter.
- **Model** — reference lap times, learned per-track sensitivity, driver/track affinity.
- **Settings** — every setting, each with a one-line description plus a tooltip
  explaining what changing it will actually cause, including the safety car mode and
  speed limit. Connection settings need a restart.

Every action (recompute, re-apply, a safety car call or end, a handicap edit or unpin,
a driver toggle, saving settings) confirms with a toast in the corner: green when it
worked, red with the server's reason when it did not.

The tables update in place rather than being rebuilt, so the page does not flicker,
scroll position survives, and a value you are halfway through typing is never clobbered
by a poll.

---

## Releasing

Bump `__version__` in `acbop/__init__.py`, add release notes as
`docs/releases/v<version>.md` (a first line `# Title` becomes the release title), and
push to master. The `release` workflow then tags `v<version>`, builds the HUD zip and
publishes the release with it attached. It does nothing for a version that is already
released.

## Tests

```bash
python3 tests/test_convergence.py       # does the field actually converge
python3 tests/test_track_variation.py   # per-track sensitivity and driver affinity
python3 tests/test_safetycar.py         # restrictor mode: does the caller actually catch the pack
python3 tests/test_vsc_limiter.py       # limiter mode, its safety net and /csp/ endpoints
python3 tests/test_csp_script.py        # the in-game script under LuaJIT (needs: pip install lupa)
python3 tests/test_hud.py               # the HUD under LuaJIT, whole app in a faked race (needs: pip install lupa)
```

The Python tests spin up a fake AC server that speaks ACSP over a real UDP socket and
drive the whole stack. The packet encoders in `tests/simserver.py` are written
independently of the decoders in `acbop/protocol.py`, so a disagreement between them
shows up as a test failure rather than a silent bug on race night. The two Lua tests run
the in-game script and the HUD under LuaJIT, CSP's Lua engine, with the game's functions
replaced by stand-ins; without `lupa` installed they print SKIP.

Representative result — six drivers spread across 7.8% of lap time:

```
race   spread%  P1-last%   handicaps (kg/%)
 raw     2.371      7.79
   1     0.707      2.11   Alien:120/25 Quick:120/20 ... Slow:25/6
   8     0.724      2.17   Alien:120/25 Quick:102/17 ... Slow:25/6
```

The restrictor-mode safety car test simulates real running through a phase. Each car's speed comes from
the restrictor it is carrying at that moment, through a restrictor that bites less than
linearly, on a track with slow corners and fast straights. The test asserts that no
ballast is ever added, that every held car settles on the target pace, and that the
caller genuinely closes:

```
    t     gap   total restrictor (measured slowdown)
    0.3   17.0s     77%(+0%)   74%(+0%)   70%(+0%)
   24.9   13.3s     82%(+16%)   80%(+15%)   78%(+15%)
   49.4    9.8s     86%(+15%)   80%(+15%)   75%(+15%)
   73.9    6.3s     82%(+15%)   77%(+15%)   78%(+15%)
 gap 17.0s -> 3.0s in 98s of running   (predicted ETA was 101s)
```

The limiter test plays the client script's part, capping held cars at 100 km/h, and
leaves one car without it. That car is caught and restricted, nobody else's ballast or
restrictor is touched, and the caller closes 22.5 s to under 3 s in 37 s. It also checks
that `/csp/` is reachable without the GUI password while the admin API is not.

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
in normal running. In limiter mode a safety car sends no penalties to held cars at all,
only the caller's handicap being dropped and restored. In restrictor mode the held cars
see a few notifications as the hold settles; `vsc_deadband_restrictor` (default 3%) stops
it resending small corrections, and raising it or `vsc_tick_s` cuts them further.

**Restrictor mode is limited by the restrictor ceiling.** A vanilla acServer caps the
restrictor at 100%, which is worth roughly 20% of lap time. The quickest held car at
100% sets the pace for the whole group, and slower drivers get just enough restrictor to
match it. That closes about 0.17 s of gap per second, so a 20-second gap takes around
100 seconds. Limiter mode has no such ceiling, which is why it is the default.

**The in-game limiter and HUD have not been run in Assetto Corsa yet.** They are built
only on CSP functions confirmed in its Lua SDK or in a working public limiter script, and
tested under LuaJIT with the game's functions stubbed out. Worth checking on your first
session: how the limiter feels (throttle fade, the brake, how fast the cap comes down)
and the leaderboard spacing.

**The web port is public in limiter mode.** Players' games fetch the script and poll
`/csp/state` from it, so it has to be reachable. Only `/csp/` skips the password, and
it only exposes what players can see in-game. Put the GUI behind a strong
`web_password`.

**The HUD matches drivers by name.** CSP gives a client no reliable way to read a car's
server slot, so two drivers with identical names would show the same handicap on the
leaderboard. The in-game limiter is not affected: it knows its own slot from the
`{SessionID}` in its URL.

**Pit detection is approximate.** ACSP gives no pit event, so a sustained stop is
treated as "the next lap is an out-lap". A driver who parks on track and rejoins loses
one lap of data. Harmless.

**Restrictor behaviour mid-session is worth verifying on your own server** before you
build a league around it — check with a manual `/restrictor <car_id> 20` that it applies
immediately rather than at the next pit stop.

---

MIT.
