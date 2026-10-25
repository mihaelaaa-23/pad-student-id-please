#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3000}"
BASE_URL="${BASE_URL%/}"
REQUESTS="${REQUESTS:-10}"
CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-5}"

if [[ ! "$REQUESTS" =~ ^[0-9]+$ ]] || (( REQUESTS < 2 )); then
  echo "ERROR: REQUESTS must be an integer greater than or equal to 2." >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

check_route() {
  local service="$1"
  local path="$2"
  local ids_file="$tmp_dir/${service}.ids"
  local headers="$tmp_dir/headers"
  local body="$tmp_dir/body"
  local code
  local instance_id
  local i
  local unique_count

  : > "$ids_file"

  printf '\n========== %s: %s ==========\n' "$service" "$path"

  for ((i = 1; i <= REQUESTS; i++)); do
    if ! code="$(curl --silent --show-error \
      --max-time "$CURL_TIMEOUT_SECONDS" \
      -D "$headers" \
      -o "$body" \
      -w '%{http_code}' \
      "${BASE_URL}${path}")"; then
      echo "FAIL: request $i could not reach the Gateway." >&2
      return 1
    fi

    instance_id="$(
      awk 'tolower($1) == "x-instance-id:" {
        gsub("\r", "", $2)
        print $2
      }' "$headers" | tail -n 1
    )"

    printf 'Request %02d: HTTP=%s X-Instance-Id=%s\n' \
      "$i" "$code" "${instance_id:-MISSING}"

    if [[ "$code" != "200" ]]; then
      echo "FAIL: expected HTTP 200, received $code." >&2
      return 1
    fi

    if [[ -z "$instance_id" ]]; then
      echo "FAIL: response has no X-Instance-Id header." >&2
      return 1
    fi

    printf '%s\n' "$instance_id" >> "$ids_file"
  done

  unique_count="$(sort -u "$ids_file" | wc -l | tr -d '[:space:]')"

  if (( unique_count < 2 )); then
    echo "FAIL: only $unique_count distinct instance ID(s) observed." >&2
    return 1
  fi

  printf 'PASS: %s requests returned HTTP 200 across %s distinct instances:\n' \
    "$REQUESTS" "$unique_count"
  sort -u "$ids_file" | sed 's/^/  - /'
}

check_route "server-rules" "/server-rules/status"
check_route "university-record" "/university-record/status"

echo
echo "PASS: I3 scaling smoke test completed."
