# Passive CAN Capture Plan

Use this when decoding Dominar 400 passive CAN signals. The goal is to change
one physical input at a time so each CAN byte can be linked to a real action.

## Before Starting

1. Flash firmware and upload LittleFS.
2. Connect phone to `D400Telemetry`.
3. Open `http://192.168.4.1` and confirm the dashboard loads.
4. Open `http://192.168.4.1/capture`.
5. Keep the bike in a safe, ventilated place.
6. For rear-wheel tests, use the paddock stand and keep the engine off.

## Capture Rules

1. Press `Start New Capture`.
2. Press the matching marker before doing each physical action.
3. Hold each state for 8 to 12 seconds.
4. Press `Stop Capture`.
5. Press `Download CSV`.
6. Save/download the file before starting the next capture, because a new
   capture overwrites `/capture.csv` on the ESP32.

## Session 1: Ignition Baseline

1. Bike ignition ON.
2. Engine OFF.
3. Bike still.
4. Press `Ignition ON, Engine OFF, Still`.
5. Wait 20 seconds.
6. Stop and download.

This identifies constant IDs and engine-off sentinel values.

## Session 2: Switches

1. Start capture.
2. Press `Side Stand Down`; keep side stand down for 8 seconds.
3. Press `Side Stand Up`; keep side stand up for 8 seconds.
4. Press `Clutch Released`; wait 8 seconds.
5. Press `Clutch Pulled`; hold clutch for 8 seconds.
6. Optional: press `Kill Run`, wait, then `Kill Off`, wait.
7. Stop and download.

This should reveal stand, clutch, and kill-switch bits.

## Session 3: Throttle, Engine Off

1. Start capture.
2. Press `Closed`; hold throttle closed for 8 seconds.
3. Press `25%`; hold roughly quarter throttle for 8 seconds.
4. Press `50%`; hold roughly half throttle for 8 seconds.
5. Press `100%`; hold full throttle for 8 seconds.
6. Press `Released`; release throttle for 8 seconds.
7. Stop and download.

Engine off is best first because RPM and MAP do not move.

## Session 4: Rear Wheel Speed, Engine Off

1. Put bike on paddock stand.
2. Engine OFF, ignition ON.
3. Start capture.
4. Press `Stopped`; wait 8 seconds.
5. Press `Slow`; rotate rear wheel slowly by hand for 10 seconds.
6. Press `Medium`; rotate faster for 10 seconds.
7. Press `Fast`; rotate faster again for 10 seconds.
8. Press `Stopped`; stop wheel and wait 8 seconds.
9. Stop and download.

Do not run the engine in gear for this first speed decode.

## Session 5: Gear Position, Engine Off

1. Start capture.
2. Press `N`; wait 8 seconds.
3. Press `1`; shift to first and wait 8 seconds.
4. Press `N`; shift back to neutral and wait 8 seconds.
5. Press `2`, `3`, `4`, `5`, `6`; wait 8 seconds at each gear.
6. Rotate the rear wheel slightly by hand if the gearbox needs it.
7. Stop and download.

This should reveal the gear byte/bit without RPM changes.

## Session 6: Idle Warm-Up

1. Move to a ventilated area.
2. Start capture.
3. Start engine in neutral.
4. Press `Idle Start`.
5. Let it idle for 2 to 4 minutes.
6. Press `Idle Warming` every 30 to 45 seconds if convenient.
7. Stop before the bike gets too hot.
8. Download.

This is for slow-moving coolant or temperature bytes.

## Session 7: RPM Validation

1. Start engine in neutral.
2. Start capture.
3. Press `RPM Idle`; hold idle for 10 seconds.
4. Press `RPM 2000`; hold near 2000 rpm for 8 seconds.
5. Press `RPM 3000`; hold near 3000 rpm for 8 seconds.
6. Press `RPM 4000`; hold near 4000 rpm for 8 seconds.
7. Press `RPM Release`; return to idle for 10 seconds.
8. Stop and download.

This validates the known `0x310` cluster-RPM value and helps find any more
precise passive RPM signal.

## Analyze On Laptop

Copy each downloaded CSV into the project, for example:

```bash
mkdir -p captures
cp ~/Downloads/d400_capture.csv captures/session_1_baseline.csv
python3 scripts/analyze_passive_capture.py captures/session_1_baseline.csv --out-dir analysis/session_1_baseline
```

Important reports:

- `stage_summary.csv`: verifies every marker has enough frames.
- `candidate_signals.csv`: broad list of bytes/pairs/bits that changed.
- `throttle_candidate_signals.csv`: likely TPS signals.
- `speed_candidate_signals.csv`: likely rear-wheel speed signals.
- `gear_candidate_signals.csv`: likely gear signals.
- `slow_moving_candidate_signals.csv`: possible coolant/temperature signals.
