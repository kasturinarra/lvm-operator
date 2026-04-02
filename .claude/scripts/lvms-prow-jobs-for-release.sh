#!/bin/bash
set -euo pipefail

# Prow Jobs Analyzer for LVMS
# Analyzes status of LVMS periodic jobs in qe-private-deck GCS bucket
# Jobs are under openshift-tests-private, not lvm-operator

GCS_BUCKET="gs://qe-private-deck"
GCS_SA="qe-private-deck@openshift-ci-private.iam.gserviceaccount.com"
GCSWEB_BASE="https://gcsweb-qe-private-deck-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/qe-private-deck"
JOB_FILTER="lvms"
JOB_EXCLUDE_FILTER=""
CI_CONFIG_BASE="https://raw.githubusercontent.com/openshift/release/master/ci-operator/config/openshift/openshift-tests-private"

# Ensure GCS access is available
# Works with either GOOGLE_APPLICATION_CREDENTIALS or gcloud service account
ensure_gcs_auth() {
    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
        return 0
    fi
    local current_account
    current_account=$(gcloud config get-value account 2>/dev/null)
    if [[ "${current_account}" != "${GCS_SA}" ]]; then
        gcloud config set account "${GCS_SA}" >/dev/null 2>&1
    fi
}

# Build exclude filter from CI config by finding LVMS jobs with LVM_OPERATOR_SUB_CHANNEL
build_exclude_filter() {
    local release="${1}"
    local exclude_jobs=()

    echo "Checking CI config for jobs with LVM_OPERATOR_SUB_CHANNEL..." >&2

    # Fetch all config files that contain LVMS jobs for this release
    # Config file variants: __amd64-nightly, __multi-nightly, and upgrade variants
    local variants=("__amd64-nightly" "__multi-nightly")
    # Also check upgrade variants
    for prev in $(seq $((${release#4.} - 2)) $((${release#4.}))); do
        variants+=("__amd64-nightly-${release}-upgrade-from-stable-4.${prev}")
        variants+=("__multi-nightly-${release}-upgrade-from-stable-4.${prev}")
    done

    for variant in "${variants[@]}"; do
        local config_url="${CI_CONFIG_BASE}/openshift-openshift-tests-private-release-${release}${variant}.yaml"
        local config
        config=$(curl -sL -f "${config_url}" 2>/dev/null) || continue

        # Parse YAML: find LVMS job names that have LVM_OPERATOR_SUB_CHANNEL
        # Look for "- as: <name>" blocks containing both "lvms" and "LVM_OPERATOR_SUB_CHANNEL"
        local current_job=""
        local has_channel=false
        while IFS= read -r line; do
            if [[ "${line}" =~ ^-\ as:\ (.+) ]]; then
                # Save previous job if it had the channel
                if [[ -n "${current_job}" && "${has_channel}" == true ]]; then
                    exclude_jobs+=("${current_job}")
                fi
                current_job="${BASH_REMATCH[1]}"
                has_channel=false
            elif [[ "${line}" =~ LVM_OPERATOR_SUB_CHANNEL ]]; then
                has_channel=true
            fi
        done <<< "${config}"
        # Handle last job in file
        if [[ -n "${current_job}" && "${has_channel}" == true ]]; then
            exclude_jobs+=("${current_job}")
        fi
    done

    if [[ ${#exclude_jobs[@]} -gt 0 ]]; then
        # Build regex pattern from excluded job names
        local pattern
        pattern=$(printf "%s|" "${exclude_jobs[@]}")
        pattern="${pattern%|}"  # Remove trailing |
        echo "Excluding ${#exclude_jobs[@]} jobs with LVM_OPERATOR_SUB_CHANNEL: ${exclude_jobs[*]}" >&2
        JOB_EXCLUDE_FILTER="${pattern}"
    fi
}

# List all LVMS periodic job directories for a release
list_lvms_jobs() {
    local release="${1}"
    local result
    result=$(gcloud storage ls "${GCS_BUCKET}/logs/" --project=openshift-ci-private 2>/dev/null | \
        grep "release-${release}" | \
        grep -i "${JOB_FILTER}" | \
        sed 's|.*/logs/||; s|/$||' | \
        sort -u)
    if [[ -n "${JOB_EXCLUDE_FILTER}" ]]; then
        result=$(echo "${result}" | grep -v -E "${JOB_EXCLUDE_FILTER}")
    fi
    echo "${result}"
}

# Get latest build result for a job
get_latest_build() {
    local job="${1}"
    local builds finished result timestamp

    # Get the latest build ID (last directory)
    builds=$(gcloud storage ls "${GCS_BUCKET}/logs/${job}/" --project=openshift-ci-private 2>/dev/null | \
        grep -oP '/\d+/$' | sed 's|/||g' | sort -n | tail -1)

    if [[ -z "${builds}" ]]; then
        echo "UNKNOWN	0	0	${GCSWEB_BASE}/logs/${job}/"
        return
    fi

    # Fetch finished.json for the latest build
    finished=$(gcloud storage cat "${GCS_BUCKET}/logs/${job}/${builds}/finished.json" --project=openshift-ci-private 2>/dev/null) || true

    if [[ -z "${finished}" ]]; then
        echo "PENDING	0	0	${GCSWEB_BASE}/logs/${job}/${builds}"
        return
    fi

    result=$(echo "${finished}" | jq -r '.result // "UNKNOWN"')
    timestamp=$(echo "${finished}" | jq -r '.timestamp // 0')

    # Calculate duration from started.json
    local started_ts duration_s
    started_ts=$(gcloud storage cat "${GCS_BUCKET}/logs/${job}/${builds}/started.json" --project=openshift-ci-private 2>/dev/null | \
        jq -r '.timestamp // 0') || started_ts=0
    if [[ "${started_ts}" -gt 0 && "${timestamp}" -gt 0 ]]; then
        duration_s=$(( timestamp - started_ts ))
    else
        duration_s=0
    fi

    local finished_date
    if [[ "${timestamp}" -gt 0 ]]; then
        finished_date=$(date -d "@${timestamp}" +"%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
    else
        finished_date="unknown"
    fi

    echo "${result}	${finished_date}	${duration_s}	${GCSWEB_BASE}/logs/${job}/${builds}"
}

# Map result to icon
result_to_icon() {
    case "${1}" in
        SUCCESS) echo "✓" ;;
        FAILURE|error) echo "✗" ;;
        ABORTED) echo "⊘" ;;
        PENDING) echo "⋯" ;;
        *)       echo "?" ;;
    esac
}

# Status mode - show latest run for each job
mode_status() {
    local release="${1}"
    local jobs

    echo "Fetching LVMS periodic jobs for release ${release}..." >&2
    jobs=$(list_lvms_jobs "${release}")

    if [[ -z "${jobs}" ]]; then
        echo "No LVMS periodic jobs found for release ${release}."
        return
    fi

    local job_count
    job_count=$(echo "${jobs}" | wc -l)
    echo "Found ${job_count} LVMS jobs. Fetching latest results..." >&2

    {
        echo -e "JOB\tSTATUS\tFINISHED\tDURATION\tURL"
        while IFS= read -r job; do
            local result_line result icon finished duration url
            result_line=$(get_latest_build "${job}")
            IFS=$'\t' read -r result finished duration url <<< "${result_line}"
            icon=$(result_to_icon "${result}")

            # Format duration
            local duration_fmt
            if [[ "${duration}" -gt 0 ]]; then
                duration_fmt="$(( duration / 3600 ))h$(( (duration % 3600) / 60 ))m"
            else
                duration_fmt="-"
            fi

            echo -e "${job}\t${icon}\t${finished}\t${duration_fmt}\t${url}"
        done <<< "${jobs}"
    } | column -t -s $'\t'
}

# Failed mode - show only failed jobs
mode_failed() {
    local release="${1}"
    local jobs

    echo "Fetching LVMS periodic jobs for release ${release}..." >&2
    jobs=$(list_lvms_jobs "${release}")

    if [[ -z "${jobs}" ]]; then
        echo "No LVMS periodic jobs found for release ${release}."
        return
    fi

    local job_count
    job_count=$(echo "${jobs}" | wc -l)
    echo "Found ${job_count} LVMS jobs. Checking for failures..." >&2

    {
        echo -e "JOB\tSTATUS\tFINISHED\tDURATION\tURL"
        while IFS= read -r job; do
            local result_line result finished duration url
            result_line=$(get_latest_build "${job}")
            IFS=$'\t' read -r result finished duration url <<< "${result_line}"

            if [[ "${result}" == "FAILURE" || "${result}" == "error" ]]; then
                local duration_fmt
                if [[ "${duration}" -gt 0 ]]; then
                    duration_fmt="$(( duration / 3600 ))h$(( (duration % 3600) / 60 ))m"
                else
                    duration_fmt="-"
                fi
                echo -e "${job}\t✗\t${finished}\t${duration_fmt}\t${url}"
            fi
        done <<< "${jobs}"
    } | column -t -s $'\t'
}

# Usage
usage() {
    echo "Usage: ${0} [--mode MODE] <release>"
    echo "  --mode MODE: Operation mode (default: failed)"
    echo "    status: Show status of latest run for each job"
    echo "    failed: Show only latest jobs with failure status"
    echo "  release: OpenShift release version (e.g., 4.22, 4.21)"
    echo ""
    echo "Jobs with LVM_OPERATOR_SUB_CHANNEL in CI config are automatically excluded"
    echo "(these are owned by other teams testing LVMS from production)."
    echo ""
    echo "Examples:"
    echo "  ${0} 4.22              # Show failed LVMS jobs for 4.22"
    echo "  ${0} --mode status 4.22  # Show all LVMS jobs for 4.22"
    exit 1
}

# Main
main() {
    local mode="failed"
    local release=""

    # Parse arguments
    while [[ ${#} -gt 0 ]]; do
        case "${1}" in
            --mode)
                if [[ ${#} -lt 2 ]]; then
                    echo "Error: mode requires an argument"
                    usage
                fi
                mode="${2}"
                shift 2
                ;;
            -*)
                echo "Unknown option: ${1}"
                usage
                ;;
            *)
                release="${1}"
                shift
                ;;
        esac
    done

    # Validate arguments
    if [[ -z "${release}" ]]; then
        echo "Error: release argument is required"
        usage
    fi

    ensure_gcs_auth
    build_exclude_filter "${release}"

    # Execute mode
    case "${mode}" in
        status)
            mode_status "${release}"
            ;;
        failed)
            mode_failed "${release}"
            ;;
        *)
            echo "Error: Unknown mode '${mode}'"
            usage
            ;;
    esac
}

main "${@}"
