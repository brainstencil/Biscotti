### after-stop

| Measure | Value |
|---|---|
| Plan | after-stop, mode concurrent, model closed after each answer: as this Mac's policy |
| Questions asked | 4 of 4 |
| Model loads | 0 during the recording, 1 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: none) |
| Memory during the recording, app | footprint peak 0.14 GB, median 0.11 GB; resident peak 0.24 GB, median 0.21 GB |
| Memory during the recording, speech worker | footprint peak 0.11 GB, median 0.08 GB; resident peak 0.15 GB, median 0.10 GB |
| Memory during the recording, AI worker | footprint peak –, median –; resident peak –, median – |
| Memory during the recording, sum | footprint peak 0.25 GB, median 0.20 GB; resident peak 0.39 GB, median 0.31 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 0.25 GB, median 0.20 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 3.21 GB, median 3.03 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): fits (this run's model); 16 GB Mac, E2B (11 GB): fits (this run's model); 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.3 s, p95 2.5 s (3447 chunks) |
| Live delay inside answers, to update | no chunks |
| Live delay outside answers, to update | median 0.8 s, p95 1.9 s (7188 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | – |
| Longest live decode outside answers | 4.07 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 8.8 s |
| Time to first token, warm | median 0.7 s (3 answers) |
| Tokens per second | median 80.3 |
| Citation validity | 23 of 28 (82%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | undetermined (no live decode lines in the answer windows) |
