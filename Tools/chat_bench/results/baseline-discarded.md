### baseline-discarded

| Measure | Value |
|---|---|
| Plan | baseline, mode concurrent, model closed after each answer: as this Mac's policy |
| Questions asked | 0 of 0 |
| Model loads | 1 during the recording, 0 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: idle 1) |
| Memory during the recording, app | footprint peak 0.19 GB, median 0.11 GB; resident peak 0.26 GB, median 0.23 GB |
| Memory during the recording, speech worker | footprint peak 0.14 GB, median 0.08 GB; resident peak 0.27 GB, median 0.18 GB |
| Memory during the recording, AI worker | footprint peak 0.36 GB, median 0.35 GB; resident peak 2.79 GB, median 2.79 GB |
| Memory during the recording, sum | footprint peak 0.60 GB, median 0.19 GB; resident peak 3.24 GB, median 0.41 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 3.04 GB, median 0.20 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.51 GB, median 0.51 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): over (this run's model); 16 GB Mac, E2B (11 GB): fits (this run's model); 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.3 s, p95 3.0 s (2068 chunks) |
| Live delay inside answers, to update | no chunks |
| Live delay outside answers, to update | median 0.8 s, p95 1.8 s (6065 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | – |
| Longest live decode outside answers | 2.46 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median –; per answer (s): – |
| Time to first token, cold | – |
| Time to first token, warm | median – (0 answers) |
| Tokens per second | – |
| Citation validity | 0 of 0 |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | 2 answers not asked by the driver (someone asked in the app): their load falls outside the answer windows |
| Contention rule | undetermined (no answers) |
