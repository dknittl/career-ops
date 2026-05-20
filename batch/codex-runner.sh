#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$SCRIPT_DIR/batch-state.tsv"
INPUT_FILE="$SCRIPT_DIR/batch-input.tsv"
LOGS_DIR="$SCRIPT_DIR/logs"
TRACKER_DIR="$SCRIPT_DIR/tracker-additions"
DATE="${CAREER_OPS_DATE:-$(date +%Y-%m-%d)}"
START_FROM=0
ONLY_ID=""

usage() {
  cat <<'USAGE'
career-ops Codex batch runner

Usage: batch/codex-runner.sh [--start-from N] [--id N]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-from) START_FROM="$2"; shift 2 ;;
    --id) ONLY_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "$LOGS_DIR" "$TRACKER_DIR"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: $STATE_FILE not found. Run batch-runner dry run first."
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: $INPUT_FILE not found."
  exit 1
fi

input_notes() {
  local id="$1"
  awk -F'\t' -v id="$id" '$1 == id { print $4 }' "$INPUT_FILE"
}

update_state_completed() {
  local id="$1" url="$2" report_num="$3" score="$4"
  local tmp="$STATE_FILE.tmp"
  local completed_at
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  awk -F'\t' -v OFS='\t' -v id="$id" -v url="$url" -v report="$report_num" -v score="$score" -v completed_at="$completed_at" '
    NR == 1 { print; next }
    $1 == id {
      $2 = url
      $3 = "completed"
      $5 = completed_at
      $6 = report
      $7 = score
      $8 = "-"
      print
      next
    }
    { print }
  ' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

while IFS=$'\t' read -r id url status started completed report_num score error retries; do
  [[ "$id" == "id" ]] && continue
  [[ -z "$id" || -z "$url" ]] && continue
  [[ "$id" =~ ^[0-9]+$ ]] || continue
  (( id >= START_FROM )) || continue
  if [[ -n "$ONLY_ID" && "$id" != "$ONLY_ID" ]]; then
    continue
  fi

  tracker_file="$TRACKER_DIR/${id}.tsv"
  if [[ -f "$tracker_file" ]]; then
    existing_score="$(awk -F'\t' '{gsub(/\/5$/, "", $6); print $6; exit}' "$tracker_file")"
    update_state_completed "$id" "$url" "$report_num" "${existing_score:-"-"}"
    echo "SKIP #$id: tracker TSV already exists"
    continue
  fi

  notes="$(input_notes "$id")"
  company="${notes%% | *}"
  role="${notes#* | }"
  log_file="$LOGS_DIR/codex-${report_num}-${id}.log"

  echo "--- Codex processing #$id: $company | $role (report $report_num)"

  prompt="Process exactly one career-ops batch item. Work quietly; do not print large file contents or diffs. Use the repository instructions and the career-ops data contract. Read cv.md, config/profile.yml, modes/_profile.md, modes/_shared.md, modes/oferta.md, modes/pdf.md, templates/cv-template.html, and batch/batch-prompt.md only as needed. URL: $url. Company: $company. Role: $role. Batch ID: $id. Report number: $report_num. Date: $DATE. Extract and verify the JD using direct fetch/API first; use Playwright only if direct extraction is insufficient. Produce a full A-G report in reports/${report_num}-<company-slug>-${DATE}.md, generate an ATS PDF if score >= 3.0, write exactly one tracker TSV to batch/tracker-additions/${id}.tsv using canonical English status Evaluated or SKIP, and print final JSON with status, report_num, company, role, score, pdf, report, error. Do not edit cv.md. Do not submit applications. Do not modify data/applications.md directly. Do not update data/pipeline.md."

  if codex exec --dangerously-bypass-approvals-and-sandbox -C "$PROJECT_DIR" "$prompt" > "$log_file" 2>&1; then
    if [[ -f "$tracker_file" ]]; then
      new_score="$(awk -F'\t' '{gsub(/\/5$/, "", $6); print $6; exit}' "$tracker_file")"
      update_state_completed "$id" "$url" "$report_num" "${new_score:-"-"}"
      echo "    completed score=${new_score:-"-"}"
    else
      echo "    failed: codex exited 0 but tracker TSV missing"
    fi
  else
    echo "    failed: see $log_file"
  fi
done < "$STATE_FILE"
