# 0009 — chatbot-eval slice

## What to build

The backend now has a fourth spoke, `metrics`, whose assistant messages carry
`metric_citations`. Measure it — still as a black-box API client (your ADR 0001 and the
control repo's ADR 0013): no gateway, warehouse or index client.

- `ROUTES` gains `metrics`; `expected_metrics` (metric names) is valid only with
  `expected_route: metrics`.
- `questions.yaml`: ≥ 8 metrics questions over the Olist and funnel catalogs, stratified:
  simple metric + state filter + year ("What was GMV in SP in 2017?"), group-by ("revenue by
  state"), category value ("health and beauty sales in 2018"), funnel ("MQL to deal
  conversion by origin"), a saved-query shape ("monthly GMV by state"); plus confusers: a
  documents question using "revenue", small talk about money, a coding question
  ("Write a linked list in Python" → `general`). Ground truth must not depend on numbers you
  cannot know — expected metric names and route only.
  Catalog names: olist `gmv`, `order_count`, `freight_value`, `avg_order_value`,
  `late_delivery_rate`, `cancellation_rate`, `avg_review_score`; funnel `mql_count`,
  `closed_deal_count`, `mql_to_deal_conversion`.
- `retrieval_recall` on a `metrics` example: expected metric names vs `metric` of
  `metric_citations`; null for `general`.
- `groundedness` on `metrics`: against the cited results (definition + rows), which are in
  the message — no extra fetch.
- Summary and confusion matrix over four routes. Thresholds keep their names and values.
- `evalset/README.md`: the new stratum, its confusers, and why metric numbers are not
  ground truth.

## Contract entries this depends on

- `contracts/openapi.yaml` 1.8.0 → `Message.route` (`metrics`), `Message.metric_citations`,
  `MetricCitation`.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and
report it rather than working around it.

## Verification

- [ ] unit: loader accepts `metrics` and refuses `expected_metrics` elsewhere; recall and
      groundedness on metrics examples; four-way confusion matrix.
- [ ] `make contract` green; the repo's own gates pass, docs moved with the code.

## Smoke — what this slice is actually judged on

Jobs: `eval-run-meets-its-thresholds` (exit 0; routing ≥ 0.8 and recall ≥ 0.6 under the
heuristic coordinator) and `a-breached-threshold-exits-non-zero` (exit 1). Steps:
`the-eval-dataset-for-metrics`, `the-question-set-covers-all-four-spokes`. The question set
must be honest, not tuned to the heuristic — a confuser it gets wrong is a finding, report it.

The assertions belong to the control repo: fix the cause, never the assertion.

## Notes

- `EVAL_IMAGE_TAG` is bumped to `local-0.2.0` in the control repo.
- The stack runs the eval after the metrics releases are indexed and served.
