# Common OBD-II live-data PIDs

These are the first PIDs to try if the Dominar ECU responds to standard OBD-II Mode 01 requests. Support varies by bike, ECU year, and emissions generation.

| Metric | Mode/PID | Response bytes | Formula |
| --- | --- | --- | --- |
| Supported PIDs 01-20 | 01 00 | A B C D | bitfield |
| Engine coolant temp | 01 05 | A | A - 40 °C |
| Intake manifold pressure | 01 0B | A | A kPa |
| Engine RPM | 01 0C | A B | ((256 * A) + B) / 4 rpm |
| Vehicle speed | 01 0D | A | A km/h |
| Intake air temp | 01 0F | A | A - 40 °C |
| MAF air flow | 01 10 | A B | ((256 * A) + B) / 100 g/s |
| Throttle position | 01 11 | A | A * 100 / 255 % |
| Control module voltage | 01 42 | A B | ((256 * A) + B) / 1000 V |
| Oil temperature | 01 5C | A | A - 40 °C |
| Engine fuel rate | 01 5E | A B | ((256 * A) + B) / 20 L/h |

Discovery sequence:

1. Query `01 00` to know which PIDs from `01` to `20` are supported.
2. Query `01 20`, `01 40`, `01 60`, etc. only if the previous support bitfield says the next block exists.
3. Log all raw responses. Do not assume the ECU supports car-style PIDs just because a sensor exists on the bike.
4. If standard PIDs are limited, investigate KWP2000/UDS manufacturer-specific data identifiers, read-only only.
