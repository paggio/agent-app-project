# 0009 — frontend slice

## What to build

Assistant messages may now have `route: metrics` and `metric_citations`. Render them.

- `make contract-sync` against the vendored 1.8.0; project `metricCitations` in the client.
- `ROUTE_LABELS` gains `metrics` ("Metrics").
- In `Sources` (beside call citations): one block per metric citation — the metric
  `label` (and `name`), the `definition`, the release as the first 7 characters of `sha`
  with the full sha in a `title`, filters and the time window, and `result` as a small
  table (`columns` header, `rows`; when `truncated`, "showing N of row_count"). Numbers
  right-aligned, locale-formatted; no chart.
- A `metrics` turn with empty `metric_citations`: render the answer only, no empty block.
- Accessibility: the table has a caption naming the metric; works with design tokens in
  light and dark.

## Contract entries this depends on

- `contracts/openapi.yaml` 1.8.0 → `Message.route`, `Message.metric_citations`,
  `MetricCitation`, `MetricResult`.

The contracts are FROZEN. If this slice appears to require a contract change, STOP and
report it rather than working around it.

## Verification

- [ ] unit (Vitest): a metric citation renders label, definition, short sha, the table and
      the truncation note; an empty list renders nothing.
- [ ] e2e (Playwright, `tests/e2e/metrics.spec.ts`), run by the control repo against the
      joined origin with `CHAT_MODEL=echo`: sign up, ask "What was GMV in SP in 2017?",
      see the Metrics label, `gmv`'s definition, a 7-char sha and a one-row table.
- [ ] `docs/architecture.md` updated; the repo's own gates pass.

## Smoke — what this slice is actually judged on

`the-metrics-route-is-reached-through-the-proxy` and the e2e suite (`smoke.e2e: true`).

The assertions belong to the control repo: fix the cause, never the assertion.
