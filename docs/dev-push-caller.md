# The `/dev-push` caller a product repo carries

A product repo triggers the control repo's reusable workflow; it does not deploy by
itself. `docs/adr/0018` is the decision. The file below is the whole of it — a repo's
slice adds it verbatim as `.github/workflows/dev-push.yml`.

```yaml
# /dev-push on this repo's PR: this PR's head, every other repo at the control repo's lock.
# The logic lives in Paggio/agent-app-project; this file only hands it the comment.
name: dev-push

on:
  issue_comment:
    types: [created]

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  dev-push:
    if: >-
      github.event.issue.pull_request &&
      startsWith(github.event.comment.body, '/dev-push')
    uses: Paggio/agent-app-project/.github/workflows/dev-push.yml@main
    secrets: inherit
```

What it needs, all written by the control repo's hand tools, never by hand:

| Name | Kind | Written by |
| --- | --- | --- |
| `DEV_AWS_ACCESS_KEY_ID`, `DEV_AWS_SECRET_ACCESS_KEY`, `DEV_AWS_SESSION_TOKEN`, `DEV_AWS_CREDENTIALS_EXPIRE_AT` | secret | `make push-gh-creds` |
| `DEV_AWS_REGION` | variable | `make push-gh-creds` |
| `DEPLOY_KEY_<REPO>` for all five repos | secret | `make gh-setup` |
| `DEV_AWS_DEPLOYER_ROLE_ARN` | variable | `make gh-setup --role-arn …` |

A called workflow sees the caller's `github` context, so `github.repository` is how the
control repo knows whose PR is under test. The author-association gate lives in the called
file, so it cannot be dropped here by accident.

## `/dev-eval`

The same shape calls `dev-eval.yml` (`docs/adr/0018` §13): swap `dev-push` for `dev-eval` in
the name, the `startsWith` and the `uses:` line. No caller exists yet; add one only in a
repo whose PRs should be evaluated against `dev` — chatbot-eval's own, first.
