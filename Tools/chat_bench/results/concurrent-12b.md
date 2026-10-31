### concurrent-12b

| Measure | Value |
|---|---|
| Plan | concurrent-12b, mode concurrent, model closed after each answer: no |
| Questions asked | 8 of 8 |
| Model loads | 1 during the recording, 0 outside it: gemma-4-12b-it-UD-Q4_K_XL.gguf (closes: idle 1) |
| Memory during the recording, app | footprint peak 0.15 GB, median 0.11 GB; resident peak 0.21 GB, median 0.17 GB |
| Memory during the recording, speech worker | footprint peak 0.09 GB, median 0.08 GB; resident peak 0.14 GB, median 0.09 GB |
| Memory during the recording, AI worker | footprint peak 2.81 GB, median 1.49 GB; resident peak 9.58 GB, median 8.26 GB |
| Memory during the recording, sum | footprint peak 3.03 GB, median 1.67 GB; resident peak 9.83 GB, median 8.51 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 9.78 GB, median 8.44 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.43 GB, median 0.42 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): over; 16 GB Mac, E2B (11 GB): fits; 24 GB Mac, 12B (19 GB): fits (this run's model) |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.2 s, p95 2.1 s (449 chunks) |
| Live delay inside answers, to update | median 0.9 s, p95 2.2 s (793 chunks) |
| Live delay outside answers, to update | median 0.8 s, p95 2.0 s (6392 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | 2.83 s |
| Longest live decode outside answers | 4.32 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 17.7 s |
| Time to first token, warm | median 4.0 s (7 answers) |
| Tokens per second | median 11.4 |
| Citation validity | 27 of 27 (100%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | passes |
