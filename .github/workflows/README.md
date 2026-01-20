# GitHub Actions Workflows

## Create GitHub Release

Creates a GitHub Release when the chart version in `Chart.yaml` changes on `main`.

**Triggers:**
- Push to `main` when `Chart.yaml` is modified

**Behavior:**
1. Reads `version` from `Chart.yaml` (e.g. `1.2.0`)
2. Packages the Helm chart (`helm package`)
3. Creates a GitHub Release with tag `v{version}` (e.g. `v1.2.0`), attaches the `.tgz` as an asset, and sets the release body with:
   - **Installation** — choose one: clone at tag, download tarball, or install from OCI (`gcr.io/neuraltrust-app-prod/neuraltrust-platform`)
   - **Full Changelog** — link comparing the previous tag to the new one

Creating a release triggers **Publish Helm Chart to GCR**, which publishes the chart to GCR.

**Required secret (Create GitHub Release):**
- **GH_TOKEN** — A [Personal Access Token (PAT)](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token) with `repo` scope.  
  The default `GITHUB_TOKEN` cannot start other workflows, so the release would not trigger **Publish Helm Chart to GCR**. Using a PAT when creating the release allows the `release` event to start the publish workflow.  
  - Settings → Secrets and variables → Actions → New repository secret → Name: `GH_TOKEN`  
  - If `GH_TOKEN` is not set, the workflow falls back to `GITHUB_TOKEN`; the release is created but **Publish Helm Chart to GCR** will not run.

---

## Publish Helm Chart to GCR

This workflow publishes the Helm chart to Google Container Registry (GCR) **when a GitHub Release is published** (e.g. by the Create GitHub Release workflow when you push `Chart.yaml` to `main`). It runs on `release` events of type `published` only (draft-only releases do not trigger it).

### Setup Required

#### 1. GCP Service Account

Create a service account in Google Cloud Platform with the following permissions:
- `Storage Admin` role (for pushing to GCR and making artifacts public)
- Or custom role with: `storage.objects.create`, `storage.objects.get`, `storage.objects.list`, `storage.objects.setIamPolicy`

**Note for Public Charts:** The service account needs `storage.objects.setIamPolicy` permission to make charts public. The `Storage Admin` role includes this permission.

#### 2. GitHub Secrets

Add the following secrets to your GitHub repository:

1. **GCP_PROJECT_ID**: Your Google Cloud Project ID
   - Settings → Secrets and variables → Actions → New repository secret
   - Name: `GCP_PROJECT_ID`
   - Value: Your GCP project ID (e.g., `my-project-123456`)

2. **GCP_SA_KEY**: Service Account JSON Key
   - Settings → Secrets and variables → Actions → New repository secret
   - Name: `GCP_SA_KEY`
   - Value: The full JSON content of your service account key file

#### 3. Create Service Account and Key

```bash
# Set your GCP project ID
export GCP_PROJECT_ID=your-project-id

# Create service account (if not exists)
gcloud iam service-accounts create github-actions \
  --display-name="GitHub Actions Service Account" \
  --project=$GCP_PROJECT_ID

# Grant Storage Admin role (unconditional binding)
# If gcloud prompts "Specify a condition", choose "None" (option 2) for an unconditional binding.
gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \
  --member="serviceAccount:github-actions@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# Create and download key
gcloud iam service-accounts keys create key.json \
  --iam-account=github-actions@${GCP_PROJECT_ID}.iam.gserviceaccount.com \
  --project=$GCP_PROJECT_ID

# Copy the contents of key.json to GitHub secret GCP_SA_KEY.
# Do not commit key.json; add key.json to .gitignore if needed.
```

### Usage

The workflow runs when **Create GitHub Release** creates a new release. The chart version is taken from the release tag (e.g. `v1.2.0`) or from `Chart.yaml`.

### Chart Access: Public by Default (Open Source)

**Charts are PUBLIC by default** - no authentication required! This is configured for open-source distribution.

#### Public Charts (Default)
- 🌐 **Open Source**: Anyone can access without authentication
- ✅ **No setup required**: Users can pull/install directly
- ✅ **Recommended for**: Open-source projects
- **No authentication needed:**
  ```bash
  helm pull oci://gcr.io/neuraltrust-app-prod/neuraltrust-platform --version 1.2.0
  helm install my-release oci://gcr.io/neuraltrust-app-prod/neuraltrust-platform --version 1.2.0
  ```

#### Private Charts (Optional)
- 🔒 **Secure**: Only authenticated users can access
- **To make private:** Manually adjust GCR permissions (e.g. remove `allUsers:objectViewer` from the artifacts bucket).
- **Authentication required:**
  ```bash
  gcloud auth configure-docker gcr.io
  gcloud auth application-default login
  helm pull oci://gcr.io/neuraltrust-app-prod/neuraltrust-platform --version 1.2.0
  ```

### Chart Location

```
oci://gcr.io/neuraltrust-app-prod/neuraltrust-platform
```

### Example Install

```bash
# No authentication needed (public chart)
helm pull oci://gcr.io/neuraltrust-app-prod/neuraltrust-platform --version 1.2.0
helm install my-release oci://gcr.io/neuraltrust-app-prod/neuraltrust-platform --version 1.2.0
```

### Troubleshooting

#### Authentication Errors
- Verify `GCP_SA_KEY` secret contains valid JSON
- Check service account has `Storage Admin` role
- Ensure `GCP_PROJECT_ID` is correct

#### Permission Denied
- Service account needs `storage.objects.create` permission
- Verify project ID matches the service account's project

#### Chart Not Found After Push
- Wait a few seconds for GCR to index the chart
- Verify the version matches what was pushed
- Check: `gcloud container images list --repository=gcr.io/neuraltrust-app-prod`

#### Chart Not Publicly Accessible
- Verify service account has `storage.objects.setIamPolicy` permission
- Check bucket IAM: `gsutil iam get gs://artifacts.neuraltrust-app-prod.appspot.com`
- Manually set public access: `gsutil iam ch allUsers:objectViewer gs://artifacts.neuraltrust-app-prod.appspot.com`
- **Note:** Making the artifacts bucket public makes ALL artifacts in the project public, not just the chart
