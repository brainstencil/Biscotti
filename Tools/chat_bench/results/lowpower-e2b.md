### lowpower-e2b

| Measure | Value |
|---|---|
| Plan | concurrent-e2b, mode concurrent, model closed after each answer: yes |
| Questions asked | 8 of 8 |
| Model loads | 8 during the recording, 0 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: lease ended 8) |
| Memory during the recording, app | footprint peak 0.17 GB, median 0.13 GB; resident peak 0.23 GB, median 0.19 GB |
| Memory during the recording, speech worker | footprint peak 0.12 GB, median 0.08 GB; resident peak 0.16 GB, median 0.10 GB |
| Memory during the recording, AI worker | footprint peak 0.35 GB, median 0.32 GB; resident peak 2.79 GB, median 2.75 GB |
| Memory during the recording, sum | footprint peak 0.61 GB, median 0.21 GB; resident peak 3.12 GB, median 0.30 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 3.04 GB, median 0.21 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.43 GB, median 0.30 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): over (this run's model); 16 GB Mac, E2B (11 GB): fits (this run's model); 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 2.0 s, p95 3.3 s (843 chunks) |
| Live delay inside answers, to update | median 1.9 s, p95 5.4 s (1167 chunks) |
| Live delay outside answers, to update | median 1.6 s, p95 2.9 s (6008 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | 5.16 s |
| Longest live decode outside answers | 3.19 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 19.7 s, 4.2 s, 6.4 s, 8.8 s, 15.9 s, 17.8 s, 15.8 s, 13.9 s |
| Time to first token, warm | median – (0 answers) |
| Tokens per second | median 49.0 |
| Citation validity | 50 of 50 (100%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | fails (a decode inside an answer took 5.2 s) |
