#!/usr/bin/env bash
# run-all-benchmarks.sh - orchestrates a full benchmark run from scripts/scenarios.json.
#
# Edit scripts/scenarios.json to add/change/remove scenarios - no code changes needed
# here. Runs smoke-test.sh first as a pre-flight check (pass --skip-smoke to bypass, not
# recommended), then each scenario in order via its corresponding bench-*.sh script.
# Continues past a failing scenario by default and reports failures in the final summary;
# pass --stop-on-failure to abort on the first one instead.
#
# Each scenario runs as a genuinely separate child process (`bash "$script" "$@"`), so an
# `exit` inside one bench-*.sh only ends that scenario, never this orchestrator - unlike
# the PowerShell version this replaces, no special process-isolation trick is needed here.
#
# Usage:
#   ./scripts/run-all-benchmarks.sh
#   ./scripts/run-all-benchmarks.sh --scenarios-file ./scripts/scenarios.json --skip-smoke
#   ./scripts/run-all-benchmarks.sh --stop-on-failure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SCENARIOS_FILE="$SCRIPT_DIR/scenarios.json"
SKIP_SMOKE=false
STOP_ON_FAILURE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenarios-file) SCENARIOS_FILE="$2"; shift 2 ;;
        --skip-smoke) SKIP_SMOKE=true; shift ;;
        --stop-on-failure) STOP_ON_FAILURE=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$SCENARIOS_FILE" ]; then
    echo "Scenarios file not found: $SCENARIOS_FILE" >&2
    exit 1
fi

scenario_count="$(jq '.scenarios | length' "$SCENARIOS_FILE")"
echo "Loaded $scenario_count scenario(s) from $SCENARIOS_FILE"

if [ "$SKIP_SMOKE" != true ]; then
    echo
    echo "=== Pre-flight: smoke-test.sh ==="
    if ! bash "$SCRIPT_DIR/smoke-test.sh"; then
        echo "Smoke test failed - aborting the full run. Fix the environment first (see README.md), or pass --skip-smoke to bypass (not recommended)." >&2
        exit 1
    fi
fi

summary_rows=()
failures=0

for i in $(seq 0 $((scenario_count - 1))); do
    category="$(jq -r ".scenarios[$i].category" "$SCENARIOS_FILE")"
    script="$(jq -r ".scenarios[$i].script" "$SCENARIOS_FILE")"
    label="$(jq -r ".scenarios[$i].label" "$SCENARIOS_FILE")"
    script_path="$SCRIPT_DIR/$script"

    echo
    echo "=== [$category] $label -> $script ==="

    if [ ! -f "$script_path" ]; then
        echo "SKIP: script not found: $script_path" >&2
        summary_rows+=("$category|$label|SKIPPED (script not found)")
        continue
    fi

    # scenario.params keys are already kebab-case flag names (minus "--") - see
    # scripts/scenarios.json. Boolean true becomes a bare "--flag" (switch), false is
    # omitted entirely; everything else becomes "--flag value".
    args=(--label "$label")
    while IFS=$'\t' read -r key value is_bool; do
        [ -z "$key" ] && continue
        if [ "$is_bool" = "true" ]; then
            if [ "$value" = "true" ]; then args+=("--$key"); fi
        else
            args+=("--$key" "$value")
        fi
    done < <(jq -r ".scenarios[$i].params // {} | to_entries[] | [.key, (.value|tostring), (.value|type==\"boolean\")] | @tsv" "$SCENARIOS_FILE")

    exit_code=0
    bash "$script_path" "${args[@]}" || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        status="OK"
    else
        status="FAILED (exit $exit_code)"
        failures=$((failures + 1))
    fi
    summary_rows+=("$category|$label|$status")

    if [ "$exit_code" -ne 0 ] && [ "$STOP_ON_FAILURE" = true ]; then
        echo
        echo "Stopping (--stop-on-failure) after failure in '$label'."
        break
    fi
done

echo
echo "=== Summary ==="
printf "%-14s %-24s %s\n" "Category" "Label" "Status"
for row in "${summary_rows[@]}"; do
    IFS='|' read -r c l s <<< "$row"
    printf "%-14s %-24s %s\n" "$c" "$l" "$s"
done

echo
echo "Full metrics table: results/run-index.csv"

if [ "$failures" -gt 0 ]; then
    echo "$failures scenario(s) failed." >&2
    exit 1
fi
echo "All scenarios completed successfully."
