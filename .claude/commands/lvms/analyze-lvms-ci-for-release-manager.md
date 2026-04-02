---
name: Analyze LVMS CI for Release Manager
argument-hint: <release1,release2,...>
description: Analyze LVMS CI for multiple releases and produce an HTML summary
allowed-tools: Skill, Bash, Read, Write, Glob, Grep, Agent
---

# analyze-lvms-ci-for-release-manager

## Synopsis
```bash
/analyze-lvms-ci-for-release-manager <release1,release2,...>
```

## Description
Accepts a comma-separated list of release versions, runs `/analyze-lvms-ci-for-release` for each, and produces a single HTML summary.

## Arguments
- `$ARGUMENTS` (required): Comma-separated release versions (e.g., `4.20,4.21,4.22`)

## Work Directory
```bash
WORKDIR=/tmp/analyze-ci-claude-workdir.$(date +%y%m%d)
```

## Steps

### Step 1: Parse and Validate
1. `WORKDIR=/tmp/analyze-ci-claude-workdir.$(date +%y%m%d) && mkdir -p ${WORKDIR}`
2. Split `$ARGUMENTS` by comma, trim whitespace
3. If empty, show usage and stop

### Step 2: Analyze Each Release
For each release, launch `/analyze-lvms-ci-for-release` as an **Agent** (NOT Skill) with `run_in_background: true`:
```
Run /analyze-lvms-ci-for-release <version>
```
Launch ALL releases in parallel. Wait for all to complete.

### Step 3: Generate HTML Report
Launch `/analyze-lvms-ci-generate-html-report` as an **Agent**:
```
Run /analyze-lvms-ci-generate-html-report <comma-separated-versions>
```
Wait for completion.

### Step 4: Report Completion
Display per-release failed job counts and the path to the generated HTML file.

## Prerequisites
- `/analyze-lvms-ci-for-release` command must be available
- `GOOGLE_APPLICATION_CREDENTIALS` exported for `gs://qe-private-deck/` access
