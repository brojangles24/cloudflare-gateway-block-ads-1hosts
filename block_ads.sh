#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_LISTS=300
MAX_RETRIES=10

error() {
    echo "Error: $1"
    rm -f oisd_big_domainswild2.txt.*
    exit 1
}

silent_error() {
    echo "Silent error: $1"
    rm -f oisd_big_domainswild2.txt.*
    exit 0
}

echo "Downloading oisd_big_domainswild2.txt..."
curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors \
  https://raw.githubusercontent.com/sjhgvr/oisd/main/domainswild2_big.txt \
  | grep -vE '^\s*(#|$)' > oisd_big_domainswild2.txt || silent_error "Failed download"

[[ -s oisd_big_domainswild2.txt ]] || error "Downloaded file empty"

# No-change detection
if [[ -f oisd_big_domainswild2.txt.old ]]; then
    cmp -s oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old && silent_error "No changes"
fi
cp oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old

total_lines=$(wc -l < oisd_big_domainswild2.txt)
(( total_lines <= MAX_LIST_SIZE * MAX_LISTS )) || error "Too many domains"

current_lists=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
  -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json") || error "List fetch fail"

current_policies=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
  -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json") || error "Rules fetch fail"

# Identify existing lists for this block
existing_ids=($(echo "$current_lists" | jq -r --arg PREFIX "$PREFIX" '
  .result|map(select(.name|startswith($PREFIX)))|sort_by(.name)|.[].id'))

# Determine next list index (no renumbering)
max_index=$(echo "$current_lists" | jq -r --arg PREFIX "$PREFIX" '
  .result
  | map(select(.name|startswith($PREFIX)))
  | map(.name | capture(".* - (?<n>[0-9]+)$").n | tonumber)
  | max // 0')

next_index=$((max_index + 1))

split -l ${MAX_LIST_SIZE} oisd_big_domainswild2.txt oisd_big_domainswild2.txt. || error "Split failed"
chunked_lists=(oisd_big_domainswild2.txt.*)

used_list_ids=()
excess_list_ids=()

# Update existing lists in sorted order
while read -r list_id; do
    if [[ ${#chunked_lists[@]} -eq 0 ]]; then
        excess_list_ids+=("$list_id")
    else
        echo "Updating $list_id..."
        name=$(echo "$current_lists" | jq -r --arg id "$list_id" '.result[]|select(.id==$id).name')
        items=$(jq -R -s 'split("\n")|map(select(length>0)|{value:.})' "${chunked_lists[0]}")
        payload=$(jq -n --arg NAME "$name" --argjson items "$items" '{name:$NAME,type:"DOMAIN",items:$items}')

        curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PUT \
          "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
          -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
          --data "$payload" || error "Update failed"

        used_list_ids+=("$list_id")
        rm -f "${chunked_lists[0]}"
        chunked_lists=("${chunked_lists[@]:1}")
    fi
done < <(printf "%s\n" "${existing_ids[@]}")

# Create new lists starting at correct index
for file in "${chunked_lists[@]}"; do
    formatted=$(printf "%03d" "$next_index")
    echo "Creating ${PREFIX} - ${formatted}"

    items=$(jq -R -s 'split("\n")|map(select(length>0)|{value:.})' "$file")
    payload=$(jq -n --arg NAME "${PREFIX} - ${formatted}" --argjson items "$items" '{name:$NAME,type:"DOMAIN",items:$items}')

    result=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X POST \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
      --data "$payload") || error "Create failed"

    used_list_ids+=("$(echo "$result" | jq -r '.result.id')")
    rm -f "$file"
    next_index=$((next_index + 1))
done

# Build policy expression
expr='{"or":[]}'
for id in "${used_list_ids[@]}"; do
    expr=$(echo "$expr" | jq --arg id "$id" '.or += [{any:{in:{lhs:{splat:"dns.domains"},rhs:$id}}}]')
done

json_data=$(jq -n --arg PREFIX "$PREFIX" --argjson EX "$expr" \
  '{name:$PREFIX,conditions:[{type:"traffic",expression:$EX}],action:"block",enabled:true,filters:["dns"]}')

policy_id=$(echo "$current_policies" | jq -r --arg PREFIX "$PREFIX" '.result|map(select(.name==$PREFIX))|.[0].id')

if [[ -z "$policy_id" || "$policy_id" == "null" ]]; then
    curl -sSfL -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_data" \
      || error "Policy create failed"
else
    curl -sSfL -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/$policy_id" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_data" \
      || error "Policy update failed"
fi

# Remove lists no longer needed
for list_id in "${excess_list_ids[@]}"; do
    echo "Deleting $list_id..."
    curl -sSfL -X DELETE \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" > /dev/null
done
