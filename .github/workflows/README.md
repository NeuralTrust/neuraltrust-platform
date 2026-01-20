# GitHub Actions Workflows

## Create GitHub Release

Creates a GitHub Release when the chart version in `Chart.yaml` changes on `main`.

**Triggers:**
- Push to `main` when `Chart.yaml` is modified

**Behavior:**
1. Reads `version` from `Chart.yaml` (e.g. `1.2.0`)
2. Packages the Helm chart (`helm package`)
3. Creates a GitHub Release with tag `v{version}` (e.g. `v1.2.0`), attaches the `.tgz` as an asset, and sets the release body with:
   - **Installation** — choose one: clone at tag, download tarball, or install from OCI (`europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform`)
   - **Full Changelog** — link comparing the previous tag to the new one

Creating a release triggers **Publish Helm Chart to Artifact Registry**, which publishes the chart to Artifact Registry.

**Required secret (Create GitHub Release):**
- **GH_TOKEN** — A [Personal Access Token (PAT)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token) with `repo` scope.  
  The default `GITHUB_TOKEN` cannot start other workflows, so the release would not trigger **Publish Helm Chart to Artifact Registry**. Using a PAT when creating the release allows the `release` event to start the publish workflow.  
  - Settings → Secrets and variables → Actions → New repository secret → Name: `GH_TOKEN`  
  - If `GH_TOKEN` is not set, the workflow falls back to `GITHUB_TOKEN`; the release is created but **Publish Helm Chart to GCR** will not run.

---

## Publish Helm Chart to Artifact Registry

This workflow publishes the Helm chart to **Google Artifact Registry** when a GitHub Release is published (e.g. by the Create GitHub Release workflow when you push `Chart.yaml` to `main`). It runs on `release` events of type `published` only. We use Artifact Registry instead of gcr.io because **gcr.io does not support OCI Helm** (404 "Repository gcr.io not found").

### Setup Required

#### 0. Create Artifact Registry repository (one-time)

Artifact Registry requires the repository to exist before the first push. Create a **Docker-format** repository named `helm-charts` in `europe-west1`:

```bash
export GCP_PROJECT_ID=your-project-id

gcloud artifacts repositories create helm-charts \
  --repository-format=docker \
  --location=europe-west1 \
  --description="Helm charts (OCI)" \
  --project=$GCP_PROJECT_ID
```

#### 1. GCP Service Account

Create a service account with:

- **Artifact Registry Writer** (`roles/artifactregistry.writer`) — required for `helm push` and `helm pull`.
- **Artifact Registry Admin** (`roles/artifactregistry.admin`) — only if you want the workflow to run **Make Chart Public** (grants `allUsers:objectViewer` on the `helm-charts` repo). If your org policy blocks `allUsers`, omit this and make the chart public manually or keep it private.

#### 2. GitHub Secrets

1. **GCP_PROJECT_ID** — Your GCP project ID  
2. **GCP_SA_KEY** — The full JSON content of your service account key file  

(Settings → Secrets and variables → Actions)

#### 3. Create Service Account and Key

```bash
export GCP_PROJECT_ID=your-project-id

gcloud iam service-accounts create github-actions \
  --display-name="GitHub Actions Service Account" \
  --project=$GCP_PROJECT_ID

gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \
  --member="serviceAccount:github-actions@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

# Optional: for "Make Chart Public" step
gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \
  --member="serviceAccount:github-actions@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.admin"

gcloud iam service-accounts keys create key.json \
  --iam-account=github-actions@${GCP_PROJECT_ID}.iam.gserviceaccount.com \
  --project=$GCP_PROJECT_ID

# Copy the contents of key.json to GitHub secret GCP_SA_KEY. Do not commit key.json.
```

### Usage

The workflow runs when **Create GitHub Release** creates a new release. The chart version is taken from the release tag or from `Chart.yaml`.

### Chart Location

```
oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform
```

### Chart Access: Public by Default (Open Source)

#### Public (default)

No authentication required:

```bash
helm pull oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform --version 1.2.0
helm install my-release oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform --version 1.2.0
```

#### Private

If you skip **Make Chart Public** or org policy blocks `allUsers`:

```bash
gcloud auth configure-docker europe-west1-docker.pkg.dev
gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin europe-west1-docker.pkg.dev
helm pull oci://europe-west1-docker.pkg.dev/neuraltrust-app-prod/helm-charts/neuraltrust-platform --version 1.2.0
```

### Troubleshooting

#### 404 "Repository … not found"
- Create the Artifact Registry repository first (Step 0). It must be **Docker** format in `europe-west1` and named `helm-charts` (or change `AR_REPO`/`AR_LOCATION` in the workflow).

#### 403 Permission denied
- Ensure the service account has **Artifact Registry Writer**. For **Make Chart Public**, it also needs **Artifact Registry Admin** (or `artifactregistry.repositories.setIamPolicy`).

#### Chart not found after push
- Wait a few seconds for Artifact Registry to index.  
- Check: `gcloud artifacts docker images list europe-west1-docker.pkg.dev/$GCP_PROJECT_ID/helm-charts --include-tags`

#### Chart not publicly accessible
- Run: `gcloud artifacts repositories add-iam-policy-binding helm-charts --location=europe-west1 --member=allUsers --role=roles/artifactregistry.reader`  
- If org policy blocks `allUsers`, the chart remains private; use the private install flow above.
