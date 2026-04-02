---
name: Analyze LVMS CI for a Release
argument-hint: <release-version>
description: Analyze all failed LVMS periodic jobs for a release and produce a summary
allowed-tools: Skill, Bash, Read, Write, Glob, Grep, Agent
---

# analyze-lvms-ci-for-release

## Synopsis
```bash
/analyze-lvms-ci-for-release <release-version>
```

## Description
Fetches failed LVMS periodic jobs for a release, analyzes each via `/ci:prow-job-analyze-test-failure`, and produces an aggregated summary.

## Arguments
- `<release-version>` (required): e.g., 4.22, 4.21

## Work Directory
```bash
WORKDIR=/tmp/analyze-ci-claude-workdir.$(date +%y%m%d)
```

## Steps

### Step 1: Fetch Failed Jobs
1. `WORKDIR=/tmp/analyze-ci-claude-workdir.$(date +%y%m%d) && mkdir -p ${WORKDIR}`
2. `bash .claude/scripts/lvms-prow-jobs-for-release.sh <release>`
3. Extract job URLs. If none found, report success and stop.

### Step 2: Analyze Each Job
For each failed job URL, launch a separate **Agent** with `run_in_background: true` and this prompt:

```
This is an LVMS job. Artifacts are in gs://qe-private-deck/ (NOT gs://test-platform-results/).
Replace gs://test-platform-results/ with gs://qe-private-deck/ and add --project=openshift-ci-private to all gcloud commands.
Some build-log.txt files are gzip-compressed — pipe through zcat if binary.

Before analyzing test failures, check artifacts/<TEST_NAME>/lvms-catalogsource/finished.json — if "passed":false, that is the root cause. Report it and skip test analysis.

## Extract Index Image Info
Before running test analysis, extract the LVMS catalog index image from the job artifacts:
1. Fetch `artifacts/<TEST_NAME>/lvms-catalogsource/build-log.txt` (may be gzip-compressed — pipe through zcat if binary)
2. Look for the line containing `LVM_INDEX_IMAGE is set to:` and extract the image reference
3. If found, run `skopeo inspect --no-tags "docker://<INDEX_IMAGE>"` to get:
   - Digest (sha256)
   - Build date (from `org.opencontainers.image.created` label)
   - Source commit (from `vcs-ref` or `org.opencontainers.image.revision` label)
4. Include this in the report under an `## Index Image` section with format:
   ```
   ## Index Image
   - **Image:** <full image reference>
   - **Digest:** <sha256 digest>
   - **Built:** <build date>
   - **Source Commit:** <commit sha>
   ```

Run /ci:prow-job-analyze-test-failure <JOB_URL>

Save the full report to: <WORKDIR>/analyze-lvms-ci-release-<RELEASE>-job-<N>-<JOB_ID>.txt
```

Launch ALL agents in parallel. Wait for all to complete.

### Step 3: Summarize
1. Read each per-job report from `${WORKDIR}`
2. Group by failure type, identify common patterns
3. Save summary to `${WORKDIR}/analyze-lvms-ci-release-<release>-summary.<timestamp>.txt`
4. Display summary — each job must include finish date `[YYYY-MM-DD]` and URL

## Prerequisites
- `.claude/scripts/lvms-prow-jobs-for-release.sh` must be executable
- `GOOGLE_APPLICATION_CREDENTIALS` exported pointing to a service account key with access to `gs://qe-private-deck/`
