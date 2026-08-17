#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/_shared.sh"
source "${SCRIPT_DIR}/lib/deploy_helpers.sh"

script_name="$(basename "$0")"

usage() {
  cat <<EOF2
Usage: $script_name [--staging] [--bucket BUCKET] [--region REGION] [--key KEY] [--content-type TYPE] [--csv CSV_FILE]
Fix the S3 Content-Type for a deployed file.

Example
--key '.well-known/apple-app-site-association'
--content-type 'application/json'

Defaults:
  BUCKET and REGION are read from nanoc.yaml unless explicitly provided.

CSV format: key,content-type
Header row is optional; blank lines and lines starting with # are ignored.
EOF2
}

staging=false
STAGING=false
bucket=""
region="${AWS_REGION:-}"
key=""
content_type=""
csv_file=""

trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

process_entry() {
  local entry_key="$1"
  local entry_type="$2"

  if [[ -z "$entry_key" || -z "$entry_type" ]]; then
    echo "Error: CSV entries must contain both key and content-type"
    exit 1
  fi

  set_s3_content_type "$bucket" "$entry_key" "$entry_type"
}

process_csv_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "Error: CSV file not found: $file"
    exit 1
  fi

  local header
  read -r header < "$file"
  local first_column
  first_column="$(printf '%s' "$header" | awk -F',' '{print tolower($1)}' | tr -d '[:space:]')"
  if [[ "$first_column" == "key" || "$first_column" == "content-type" || "$first_column" == "content_type" ]]; then
    tail -n +2 "$file" | while IFS=, read -r raw_key raw_type; do
      raw_key="$(trim "$raw_key")"
      raw_type="$(trim "$raw_type")"
      [[ -z "$raw_key" || "${raw_key:0:1}" == "#" ]] && continue
      process_entry "$raw_key" "$raw_type"
    done
  else
    while IFS=, read -r raw_key raw_type; do
      raw_key="$(trim "$raw_key")"
      raw_type="$(trim "$raw_type")"
      [[ -z "$raw_key" || "${raw_key:0:1}" == "#" ]] && continue
      process_entry "$raw_key" "$raw_type"
    done < "$file"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging)
      staging=true
      shift
      ;;
    --bucket)
      bucket="$2"
      shift 2
      ;;
    --region)
      region="$2"
      shift 2
      ;;
    --key)
      key="$2"
      shift 2
      ;;
    --content-type)
      content_type="$2"
      shift 2
      ;;
    --csv)
      csv_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "${SCRIPT_DIR}/nanoc.yaml" ]]; then
  echo "Error: nanoc.yaml not found. Run from the project root."
  exit 1
fi

if ! command -v aws &>/dev/null; then
  echo "Error: aws CLI is not installed."
  exit 1
fi

if [[ -z "$bucket" || -z "$region" ]]; then
  if [[ "$staging" == true ]]; then
    STAGING=true
  fi
  read_deploy_config
  bucket="${bucket:-$S3_BUCKET}"
  region="${region:-$AWS_REGION}"
fi

if [[ -z "$bucket" ]]; then
  echo "Error: S3 bucket not found in arguments or nanoc.yaml."
  exit 1
fi
if [[ -z "$region" ]]; then
  echo "Error: AWS region not found in arguments, environment, or nanoc.yaml."
  exit 1
fi

if [[ -n "$csv_file" ]]; then
  process_csv_file "$csv_file"
else
  set_s3_content_type "$bucket" "$key" "$content_type"
  echo "Updated Content-Type to ${content_type} for s3://${bucket}/${key}"
fi
