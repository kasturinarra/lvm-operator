---
name: Generate LVMS CI HTML Report
argument-hint: <release1,release2,...>
description: Generate an HTML report from LVMS CI analysis files
allowed-tools: Bash, Read, Write, Glob, Grep
---

# analyze-lvms-ci-generate-html-report

## Synopsis
```bash
/analyze-lvms-ci-generate-html-report <release1,release2,...>
```

## Description
Reads analysis summary files from `${WORKDIR}/` (produced by `analyze-lvms-ci-for-release`) and generates a single consolidated HTML report.

## Arguments
- `$ARGUMENTS` (required): Comma-separated release versions (e.g., `4.20,4.21,4.22`)

## Work Directory
```bash
WORKDIR=/tmp/analyze-ci-claude-workdir.$(date +%y%m%d)
```

## Steps

### Step 1: Discover Files
1. Parse releases from `$ARGUMENTS`
2. For each release, find `${WORKDIR}/analyze-lvms-ci-release-<version>-summary.*.txt`
3. If no files found, show error and stop

### Step 2: Read Summary and Per-Job Files
1. Read each release summary file for failure details
2. For each release, also read per-job files (`${WORKDIR}/analyze-lvms-ci-release-<version>-job-*.txt`) to extract the `## Index Image` section (Image, Digest, Built, Source Commit). Use the first per-job file that has valid index image data — the catalog image is the same for all jobs in a release.

### Step 3: Generate HTML Report
Save using Bash heredoc (NOT Write tool) to `${WORKDIR}/lvms-ci-release-manager-<YYYYMMDD-HHMMSS>.html`

**HTML Structure** — self-contained, no external dependencies:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>LVMS CI Release Manager Report - YYYY-MM-DD</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; color: #333; }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { color: #1a1a2e; border-bottom: 3px solid #e94560; padding-bottom: 10px; }
        .release-section { background: white; border-radius: 8px; padding: 20px; margin: 20px 0; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .release-header { display: flex; justify-content: space-between; align-items: center; }
        .release-header h2 { margin: 0; }
        .badge { padding: 4px 12px; border-radius: 12px; font-size: 0.85em; font-weight: 600; }
        .badge-ok { background: #d4edda; color: #155724; }
        .badge-issues { background: #fff3cd; color: #856404; }
        .badge-critical { background: #f8d7da; color: #721c24; }
        .overview-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin: 20px 0; }
        .overview-card { background: white; border-radius: 8px; padding: 20px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .overview-card .number { font-size: 2em; font-weight: 700; }
        .overview-card .label { color: #6c757d; font-size: 0.9em; }
        .status-pass { color: #28a745; }
        .status-fail { color: #dc3545; }
        .collapsible { cursor: pointer; user-select: none; padding: 8px; background: #f8f9fa; border-radius: 4px; margin: 5px 0; }
        .collapsible::before { content: '\25B6  '; font-size: 0.8em; }
        .collapsible.active::before { content: '\25BC  '; }
        .collapsible-content { display: none; padding: 10px; }
        .collapsible-content.show { display: block; }
        .root-cause { background: #fff8e1; border-left: 3px solid #ffc107; padding: 8px 12px; margin: 8px 0; font-size: 0.9em; }
        .job-date { color: #6c757d; font-size: 0.85em; }
        .timestamp { color: #6c757d; font-size: 0.9em; }
        a { color: #0366d6; }
    </style>
</head>
<body>
<div class="container">
    <h1>LVMS CI Release Manager Report</h1>
    <p class="timestamp">Generated: YYYY-MM-DD HH:MM:SS</p>
    <div class="overview-grid">
        <!-- One card per release -->
    </div>
    <!-- Per-release sections with collapsible issue details -->
</div>
<script>
document.querySelectorAll('.collapsible').forEach(function(el) {
    el.addEventListener('click', function() {
        this.classList.toggle('active');
        this.nextElementSibling.classList.toggle('show');
    });
});
</script>
</body>
</html>
```

- Use `badge-ok` for 0 failures, `badge-issues` for 1-4, `badge-critical` for 5+
- Make all job URLs clickable links
- Each issue from the summary gets a collapsible block
- If index image info is present in any per-job report (look in `${WORKDIR}/analyze-lvms-ci-release-<version>-job-*.txt` for `## Index Image` section with Image, Digest, Built, Source Commit), display it at the **top of each release section**, right after the release header, as a release-level detail (the catalog image is shared across all jobs in a release):
  ```html
  <div class="index-image-info">
      <strong>Catalog Index Image:</strong> <code>image:tag</code><br>
      <strong>Digest:</strong> <code>sha256:...</code><br>
      <strong>Built:</strong> date<br>
      <strong>Source Commit:</strong> <a href="https://github.com/openshift/lvm-operator/commit/HASH">HASH (short)</a>
  </div>
  ```
  To find the index image info, read the per-job report files (not just the summary) and use the first one that has valid index image data.
  Add this CSS for the info box:
  ```css
  .index-image-info { background: #e8f4fd; border-left: 3px solid #0366d6; padding: 8px 12px; margin: 8px 0; font-size: 0.9em; }
  .index-image-info code { background: #f1f1f1; padding: 2px 4px; border-radius: 3px; font-size: 0.9em; }
  ```

### Step 4: Report Completion
Display the path to the generated HTML file.
