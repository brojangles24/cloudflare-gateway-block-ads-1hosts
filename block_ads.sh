#!/bin/bash

# Cloudflare API credentials
API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_LISTS=100
MAX_RETRIES=10

# === Helper functions ===
function error() {
    echo "Error: $1"
    rm -f 1hosts_lite_domains.wildcards.txt.*
    exit 1
}

function silent_error() {
    echo "Silent error: $1"
    rm -f 1hosts_lite_domains.wildcards.txt.*
    exit 0
}

# === Download 1Hosts Lite ===
echo "Downloading 1Hosts Lite list..."
curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors \
  https://raw.githubusercontent.com/badmojr/1Hosts/master/Lite/domains.wildcards \
  | grep -vE '^\s*(#|$)' > 1hosts_lite_domains.wildcards.txt || silent_error "Failed to download the domains list"

# === Check for changes ===
git diff --exit-code 1hosts_lite_domains.wildcards.txt > /dev/null && silent_error "The domains list has not changed"
[[ -s 1hosts_lite_domains.wildcards.txt ]] || error "Downloaded list is empty"

total_lines=$(wc -l < 1hosts_lite_domains.wildcards.txt)
(( total_lines <= MAX_LIST_SIZE * MAX_LISTS )) || error "The list exceeds Cloudflare's domain cap"

total_lists=$(( (total_lines + MAX_LIST_SIZE - 1) / MAX_LIST_SIZE ))

# === Retrieve current Cloudflare lists & rules ===
current_lists=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json") || error "Failed to get current lists"

current_policies=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json") || error "Failed to get current policies"

# === Count lists ===
current_lists_count=$(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" \
  'if (.result | length > 0) then .result | map(select(.name | contains($PREFIX))) | length else 0 end') || error "Failed to count lists"

current_lists_count_without_prefix=$(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" \
  'if (.result | length > 0) then .result | map(select(.name | contains($PREFIX) | not)) | length else 0 end') || error "Failed to count lists without prefix"

[[ ${total_lists} -le $((MAX_LISTS - current_lists_count_without_prefix)) ]] || error "Too many lists required"

# === Split into chunks ===
split -l ${MAX_LIST_SIZE} 1hosts_lite_domains.wildcards.txt 1hosts_lite_domains.wildcards.txt. || error "Failed to split list"

chunked_lists=($(ls 1hosts_lite_domains.wildcards.txt.*))
used_list_ids=()
excess_list_ids=()
list_counter=1

# === Update existing lists ===
if [[ ${current_lists_count} -gt 0 ]]; then
    for list_id in $(echo "${current_lists}" | jq -r --arg PREFIX "${PREFIX}" '.result | map(select(.name | contains($PREFIX))) | .[].id'); do
        [[ ${#chunked_lists[@]} -eq 0 ]] && {
            echo "Marking extra list ${list_id} for deletion..."
            excess_list_ids+=("${list_id}")
            continue
        }

        echo "Updating list ${list_id}..."
        list_items=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
          "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}/items?limit=${MAX_LIST_SIZE}" \
          -H "Authorization: Bearer ${API_TOKEN}" \
          -H "Content-Type: application/json") || error "Failed to get list items"

        list_items_values=$(echo "${list_items}" | jq -r '.result | map(.value) | map(select(. != null))')
        list_items_array=$(jq -R -s 'split("\n") | map(select(length > 0) | { "value": . })' "${chunked_lists[0]}")
        payload=$(jq -n --argjson append_items "$list_items_array" --argjson remove_items "$list_items_values" '{ "append": $append_items, "remove": $remove_items }')

        curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PATCH \
          "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
          -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
          --data "$payload" || error "Failed to patch list ${list_id}"

        used_list_ids+=("${list_id}")
        rm -f "${chunked_lists[0]}"
        chunked_lists=("${chunked_lists[@]:1}")
        list_counter=$((list_counter + 1))
    done
fi

# === Create new lists if needed ===
for file in "${chunked_lists[@]}"; do
    echo "Creating new list..."
    formatted_counter=$(printf "%03d" "$list_counter")

    payload=$(jq -n --arg PREFIX "${PREFIX} - ${formatted_counter}" \
      --argjson items "$(jq -R -s 'split("\n") | map(select(length > 0) | { "value": . })' "${file}")" \
      '{ "name": $PREFIX, "type": "DOMAIN", "items": $items }')

    list=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X POST \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
      --data "$payload") || error "Failed to create list"

    used_list_ids+=("$(echo "${list}" | jq -r '.result.id')")
    rm -f "${file}"
    list_counter=$((list_counter + 1))
done

# === Create or update blocking policy ===
policy_id=$(echo "${current_policies}" | jq -r --arg PREFIX "${PREFIX}" \
  '.result | map(select(.name == $PREFIX)) | .[0].id') || error "Failed to get policy ID"

conditions=()
if [[ ${#used_list_ids[@]} -eq 1 ]]; then
    conditions='
        "any": { "in": { "lhs": { "splat": "dns.domains" }, "rhs": "$'"${used_list_ids[0]}"'" } }'
else
    for list_id in "${used_list_ids[@]}"; do
        conditions+=('{
            "any": { "in": { "lhs": { "splat": "dns.domains" }, "rhs": "$'"$list_id"'" } }
        }')
    done
    conditions=$(IFS=','; echo "${conditions[*]}")
    conditions='"or": ['"$conditions"']'
fi

json_data='{
    "name": "'${PREFIX}'",
    "conditions": [ { "type": "traffic", "expression": { '"$conditions"' } } ],
    "action": "block",
    "enabled": true,
    "filters": ["dns"]
}'

if [[ -z "${policy_id}" || "${policy_id}" == "null" ]]; then
    echo "Creating policy..."
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X POST \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
      --data "$json_data" > /dev/null || error "Failed to create policy"
else
    echo "Updating policy ${policy_id}..."
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PUT \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${policy_id}" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
      --data "$json_data" > /dev/null || error "Failed to update policy"
fi

# === Delete excess lists ===
for list_id in "${excess_list_ids[@]}"; do
    echo "Deleting list ${list_id}..."
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X DELETE \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" > /dev/null || error "Failed to delete list ${list_id}"
done

# === Commit and push ===
git config --global user.email "${GITHUB_ACTOR_ID}+${GITHUB_ACTOR}@users.noreply.github.com"
git config --global user.name "$(gh api /users/${GITHUB_ACTOR} | jq .name -r)"
git add 1hosts_lite_domains.wildcards.txt || error "Failed to add list"
git commit -m "Update 1Hosts Lite list" --author=. || error "Failed to commit list"
git push origin main || error "Failed to push list update"
