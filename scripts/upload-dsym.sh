#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  fail 'usage: bash scripts/upload-dsym.sh DWARF_FILE UUID ARCH'
fi

file=$1
uuid=$2
arch=$3
endpoint=https://totono.work/api/error-reporting/v1/artifacts

command -v jq >/dev/null || fail 'missing_jq'
[[ ${TOTONO_ERROR_ARTIFACT_KEY:-} =~ ^tr_art_[a-zA-Z0-9_-]{43}$ ]] || fail 'invalid_artifact_configuration'
[[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || fail 'invalid_uuid'
case "$arch" in
  arm64|arm64e|x86_64) ;;
  *) fail 'invalid_architecture' ;;
esac

[[ -f $file && -r $file ]] || fail 'invalid_dwarf_file'
size=$(wc -c < "$file")
size=${size//[[:space:]]/}
(( size > 0 && size <= 16 * 1024 * 1024 )) || fail 'invalid_file_size'

post_artifact() {
  printf 'Authorization: Bearer %s\n' "$TOTONO_ERROR_ARTIFACT_KEY" |
    curl --disable --silent --show-error --fail --max-time 30 \
      --header @- --header 'Content-Type: application/json' \
      --data-binary "$1" -- "$endpoint"
}

request=$(jq -cn --argjson size "$size" --arg uuid "$uuid" --arg arch "$arch" \
  '{action: "dsym", size: $size, uuid: $uuid, arch: $arch}')
response=$(post_artifact "$request")
id=$(jq -er '.id | strings | select(length > 0)' <<< "$response")
upload_url=$(jq -er '.upload.url | strings | select(startswith("https://"))' <<< "$response")

# Signed fields are literal strings, including values that start with @ or <.
fields=$(jq -er '.upload.fields | to_entries[] | "\(.key)=\(.value)"' <<< "$response")
form=()
while IFS= read -r field; do
  form+=(--form-string "$field")
done <<< "$fields"

status=$(curl --disable --silent --show-error --max-time 120 --output /dev/null \
  --write-out '%{http_code}' "${form[@]}" \
  --form 'file=@-;filename=artifact;type=application/octet-stream' \
  -- "$upload_url" < "$file")
[[ $status == 2[0-9][0-9] ]] || fail "storage_upload_$status"

request=$(jq -cn --arg id "$id" '{action: "complete", id: $id}')
response=$(post_artifact "$request")
jq -er --arg id "$id" '.id | select(. == $id)' <<< "$response"
