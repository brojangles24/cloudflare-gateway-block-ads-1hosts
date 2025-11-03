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
  | grep -vE '^\s*(#|$)' > oisd_big_domainswild2.txt || silent_error "Failed to download domains list"

[[ -s oisd_big_domainswild2.txt ]] || error "Downloaded list is empty"

# Detect no changes based on previous saved version
if [[ -f oisd_big_domainswild2.txt.old ]]; then
    cmp -s oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old && silent_error "No changes detected"
fi
cp oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old

total_lines=$(wc -l < oisd_big_domainswild2.txt)
(( total_lines <= MAX_LIST_SIZE * MAX_LISTS )) || error "Too many domains for Cloudflare limit"

total_lists=$(( (total_lines + MAX_LIST_SIZE - 1) / MAX_LIST_SIZE ))

current_lists=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
  -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json") || error "Failed to list lists"

current_policies=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
  -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json") || error "Failed to list rules"

echo "Renumbering existing lists..."
count=1
while read -r id; do
    formatted=$(printf "%03d" $count)
    new_name="${PREFIX} - ${formatted}"
    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PUT \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${id}" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
      --data "$(jq -n --arg NAME "$new_name" '{ "name": $NAME }')" > /dev/null
    count=$((count+1))
done < <(echo "$current_lists" | jq -r --arg PREFIX "$PREFIX" '.result | map(select(.name|contains($PREFIX))) | sort_by(.name) | .[].id')

current_lists=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
  -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")

split -l ${MAX_LIST_SIZE} oisd_big_domainswild2.txt oisd_big_domainswild2.txt. || error "Split failed"
chunked_lists=(oisd_big_domainswild2.txt.*)

used_list_ids=()
excess_list_ids=()

while read -r list_id; do
    if [[ ${#chunked_lists[@]} -eq 0 ]]; then
        excess_list_ids+=("$list_id")
    else
        echo "Updating $list_id..."
        name=$(echo "$current_lists" | jq -r --arg id "$list_id" '.result[] | select(.id==$id).name')
        items=$(jq -R -s 'split("\n") | map(select(length>0)|{value:.})' "${chunked_lists[0]}")
        payload=$(jq -n --arg NAME "$name" --argjson items "$items" '{name:$NAME, type:"DOMAIN", items:$items}')

        curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PUT \
          "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
          -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
          --data "$payload" || error "Failed updating $list_id"

        used_list_ids+=("$list_id")
        rm -f "${chunked_lists[0]}"
        chunked_lists=("${chunked_lists[@]:1}")
    fi
done < <(echo "$current_lists" | jq -r --arg PREFIX "$PREFIX" '.result | map(select(.name|contains($PREFIX))) | sort_by(.name) | .[].id')

counter=1
for file in "${chunked_lists[@]}"; do
    formatted=$(printf "%03d" "$counter")
    echo "Creating ${PREFIX} - ${formatted}"
    items=$(jq -R -s 'split("\n") | map(select(length>0)|{value:.})' "$file")
    payload=$(jq -n --arg NAME "${PREFIX} - ${formatted}" --argjson items "$items" '{name:$NAME, type:"DOMAIN", items:$items}')

    result=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X POST \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
      --data "$payload") || error "Failed list create"

    used_list_ids+=("$(echo "$result" | jq -r '.result.id')")
    rm -f "$file"
    counter=$((counter+1))
done

policy_id=$(echo "$current_policies" | jq -r --arg PREFIX "$PREFIX" '.result|map(select(.name==$PREFIX))|.[0].id')

expr='{"or":[]}'
for id in "${used_list_ids[@]}"; do
    expr=$(echo "$expr" | jq --arg id "$id" '.or += [{any:{in:{lhs:{splat:"dns.domains"},rhs:$id}}}]')
done

json_data=$(jq -n --arg PREFIX "$PREFIX" --argjson EX "$expr" \
  '{name:$PREFIX, conditions:[{type:"traffic",expression:$EX}], action:"block", enabled:true, filters:["dns"]}')

if [[ -z "$policy_id" || "$policy_id" == "null" ]]; then
    curl -sSfL -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_data" \
      || error "Policy create failed"
else
    curl -sSfL -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/$policy_id" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_data" \
      || error "Policy update failed"
fi

for list_id in "${excess_list_ids[@]}"; do
    curl -sSfL -X DELETE \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" > /dev/null
done
