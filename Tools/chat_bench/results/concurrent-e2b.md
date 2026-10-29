### concurrent-e2b

| Measure | Value |
|---|---|
| Plan | concurrent-e2b, mode concurrent, model closed after each answer: yes |
| Questions asked | 8 of 8 |
| Model loads | 8 during the recording, 0 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: lease ended 8) |
| Memory during the recording, app | footprint peak 0.16 GB, median 0.10 GB; resident peak 0.21 GB, median 0.16 GB |
| Memory during the recording, speech worker | footprint peak 0.11 GB, median 0.08 GB; resident peak 0.12 GB, median 0.09 GB |
| Memory during the recording, AI worker | footprint peak 0.34 GB, median 0.26 GB; resident peak 2.76 GB, median 2.65 GB |
| Memory during the recording, sum | footprint peak 0.55 GB, median 0.18 GB; resident peak 3.01 GB, median 0.26 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 2.96 GB, median 0.18 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.40 GB, median 0.27 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): fits (this run's model); 16 GB Mac, E2B (11 GB): fits (this run's model); 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.3 s, p95 2.5 s (441 chunks) |
| Live delay inside answers, to update | median 1.0 s, p95 2.8 s (841 chunks) |
| Live delay outside answers, to update | median 0.8 s, p95 2.1 s (6345 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | 3.25 s |
| Longest live decode outside answers | 4.75 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 6.4 s, 2.8 s, 5.3 s, 8.6 s, 11.1 s, 11.5 s, 11.7 s, 13.1 s |
| Time to first token, warm | median – (0 answers) |
| Tokens per second | median 51.9 |
| Citation validity | 49 of 49 (100%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | passes |
