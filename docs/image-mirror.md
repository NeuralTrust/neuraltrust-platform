# Mirroring images into a customer registry

One customer runs the platform from their own AWS ECR rather than pulling from
our Artifact Registry. The
[Mirror images to customer registry](../.github/workflows/mirror-images-to-registry.yml)
workflow copies the images this chart pins into their registry and then starts
their CodePipelines.

It is manual on purpose. The destination is a third-party account and each push
is coordinated with them.

> Customer identities are never recorded in this repo. The environment is named
> `client-a-preview`; the mapping to the real customer is kept outside version
> control.

Everything lives in the one workflow file: the image list, the regions, and the
pipeline names. There is no separate config to chase.

## What a run does

1. **Plan.** Reads `values.yaml` and `Chart.yaml` and prints the resolved
   versions to the run summary. This job runs before the approval gate, so
   reviewers see exactly what they are approving.
2. **Mirror.** One job per image and region, 14 in total. Each resolves its own
   version from the chart, then copies and tags.
3. **Start pipelines.** Runs only after every copy has landed, so no pipeline
   deploys a half-mirrored bundle.

Because versions come from the chart at the checked-out ref, the mirror cannot
drift from what the chart declares.

Each mirrored image gets three tags:

| Tag | Example | Purpose |
|---|---|---|
| Version | `v2.28.1` | Which build this is. Comes from the chart pin. |
| Environment | `preview` | What the customer's deployment actually pulls. |
| Chart | `chart-2.11.11` | Which platform release the image shipped in. |

Versions are per image, not one shared number: `agentgateway` and `firewall-cpu`
are released independently. The chart tag is what ties a set together.

## Running it

Actions to *Mirror images to customer registry* to *Run workflow*. All inputs
have usable defaults.

| Input | Default | Notes |
|---|---|---|
| `images` | all | Comma-separated subset, **no spaces**, e.g. `agentgateway,trustguard`. |
| `dry_run` | off | Authenticates and checks the destination repositories exist, copies nothing. |
| `start_pipelines` | on | Turn off to mirror without deploying. |
| `overwrite` | off | See below. |

Re-running is cheap and safe. Before copying, the workflow compares the source
and destination digests; if they already match it skips the layer transfer and
just re-applies the tags. Re-pointing `preview` at an already-mirrored version
therefore costs seconds even for the multi-gigabyte firewall image.

If the destination already holds that version tag with *different* content, the
run fails rather than silently replacing it. That normally means a tag was
rebuilt upstream. Confirm it is intended, then re-run with `overwrite` enabled.

### After a partial failure

Copies are independent, so one failure does not abandon the rest. Use GitHub's
**Re-run failed jobs** — it re-runs exactly the image and region pairs that
failed, which is almost always what you want.

The `images` input is for deliberately mirroring a subset. Two things to know
about it:

- Unselected combinations still start a runner and exit immediately rather than
  being skipped outright. GitHub does not expose the matrix to a job-level
  condition, so the filter is applied to the steps instead.
- **It does not filter the pipelines.** The pipeline job starts the full set. If
  you mirror a subset, run with `start_pipelines` off and trigger the deploy
  separately.

## Configuration outside the repo

A GitHub Environment named `client-a-preview`, with required reviewers and its
deployment branches limited to `main`. That gate is the only thing standing
between a repository write-collaborator and the customer's registry, so it is
not optional.

| Name | Kind | Value |
|---|---|---|
| `MIRROR_AWS_ROLE_ARN` | environment secret | Role the workflow assumes. A secret so the account id stays out of the repo. |

The registry host is derived from the assumed role's account as
`<account>.dkr.ecr.<region>.amazonaws.com`.

The customer's role must trust this repository *and* the environment:

```json
"StringEquals": {
  "token.actions.githubusercontent.com:sub":
    "repo:NeuralTrust/neuraltrust-platform:environment:client-a-preview"
}
```

Scoping to the environment rather than the repository is the point: without it,
any branch here could assume the role.

The role needs `ecr:GetAuthorizationToken`, push on each destination repository,
and `codepipeline:StartPipelineExecution` on each pipeline. It does **not** need
`ecr:CreateRepository` — the workflow checks the repositories exist and fails
early if one is missing, since creating them is the customer's side of the
boundary.

`PLATFORM_WIF_PROVIDER` and `PLATFORM_WIF_SERVICE_ACCOUNT` already exist at
repository level and are reused here. The bound service account needs **read on
the source Artifact Registry repository**. It currently writes to `helm-charts`
and lists tags for `bump-images`, which is not the same permission as pulling
image layers — confirm it before the first run, or let a `dry_run` surface it.

## Changing the image list

The images appear in two places in the workflow, and they must agree:

- the `plan` job's list, used to render the version table
- the `mirror` job's `matrix.image` entries

Nothing can feed data into a `strategy:` block except repository variables,
which would hide the list from code review, so the two lists are kept adjacent
in the same file instead. A mismatch shows up as an image missing from the plan
table.

Pipeline names live in a third list, in the `pipelines` job.

## Adding a second customer

Not built for yet, deliberately. When it happens, the cheapest move is to copy
the workflow, change the environment name, the image repositories, and the
pipeline list. If a third appears, that is the point to reintroduce a per-target
manifest and a generated matrix.
