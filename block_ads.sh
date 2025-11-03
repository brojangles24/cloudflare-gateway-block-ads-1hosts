#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_LISTS=300
MAX_RETRIES=10

error() { echo "Error: $1"; rm -f oisd_big_domainswild2.txt.*; exit 1; }
silent_error() { echo "$1"; rm -f oisd_big_domainswild2.txt.*; exit 0; }

echo "Downloading list..."
curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors \
  https://raw.githubusercontent.com/sjhgvr/oisd/main/domainswild2_big.txt \
  | grep -vE '^\s*(#|$)' > oisd_big_domainswild2.txt || silent_error "Download failed"

[[ -s oisd_big_domainswild2.txt ]] || error "List empty"

# No-change detection
if [[ -f oisd_big_domainswild2.txt.old ]]; then
    cmp -s oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old && silent_error "No changes"
fi

echo "Deduping..."
sort -u oisd_big_domainswild2.txt -o oisd_big_domainswild2.txt
cp oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old

total_lines=$(wc -l < oisd_big_domainswild2.txt)
(( total_lines <= MAX_LIST_SIZE * MAX_LISTS )) || error "Too many domains"

current_lists=$(curl -sSfL -X GET \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists" \
  -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json") \
  || error "List fetch failed"

current_policies=$(curl -sSfL -X GET \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/rules" \
  -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json") \
  || error "Policy fetch failed"

existing_ids=($(echo "$current_lists" | jq -r --arg PREFIX "$PREFIX" '
  .result|map(select(.name|startswith($PREFIX)))|sort_by(.name)|.[].id'))

max_index=$(echo "$current_lists" | jq -r --arg PREFIX "$PREFIX" '
  .result|map(select(.name|startswith($PREFIX)))
  | map(.name|capture(".* - (?<n>[0-9]+)$").n|tonumber)
  | max // 0')

next_index=$((max_index + 1))

split -l $MAX_LIST_SIZE oisd_big_domainswild2.txt oisd_big_domainswild2.txt. || error "Split failed"
chunked_lists=(oisd_big_domainswild2.txt.*)

used_list_ids=()
excess_list_ids=()

### UPDATE EXISTING LISTS (SKIP IF IDENTICAL)
while read -r list_id; do
    if [[ ${#chunked_lists[@]} -eq 0 ]]; then
        excess_list_ids+=("$list_id")
        continue
    fi

    echo "Checking $list_id..."

    existing_items=$(curl -sSfL -X GET \
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$list_id/items" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
      | jq -r '.result[].value' | sort)

    new_items_sorted=$(sort "${chunked_lists[0]}")

    if cmp -s <(echo "$existing_items") <(echo "$new_items_sorted"); then
        echo "Skipping $list_id (no changes)"
        used_list_ids+=("$list_id")
        rm -f "${chunked_lists[0]}"
        chunked_lists=("${chunked_lists[@]:1}")
        continue
    fi

    echo "Updating $list_id..."
    name=$(echo "$current_lists" | jq -r --arg id "$list_id" '.result[]|select(.id==$id).name')
    items=$(jq -R -s 'split("\n")|map(select(length>0)|{value:.})' "${chunked_lists[0]}")
    payload=$(jq -n --arg NAME "$name" --argjson items "$items" '{name:$NAME,type:"DOMAIN",items:$items}')

    curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X PUT \
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$list_id" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" --data "$payload" \
      || error "Update failed"

    used_list_ids+=("$list_id")
    rm -f "${chunked_lists[0]}"
    chunked_lists=("${chunked_lists[@]:1}")
done < <(printf "%s\n" "${existing_ids[@]}")

### CREATE NEW LISTS IF MORE CHUNKS REMAIN
for file in "${chunked_lists[@]}"; do
    formatted=$(printf "%03d" "$next_index")
    echo "Creating ${PREFIX} - ${formatted}"

    items=$(jq -R -s 'split("\n")|map(select(length>0)|{value:.})' "$file")
    payload=$(jq -n --arg NAME "${PREFIX} - ${formatted}" --argjson items "$items" '{name:$NAME,type:"DOMAIN",items:$items}')

    result=$(curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors -X POST \
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" --data "$payload") \
      || error "Create failed"

    used_list_ids+=("$(echo "$result" | jq -r '.result.id')")
    rm -f "$file"
    next_index=$((next_index + 1))
done

### BUILD POLICY EXPRESSION
chunk_size=1
expr='{"or": []}'

for ((i=0; i<${#used_list_ids[@]}; i+=chunk_size)); do
    chunk=( "${used_list_ids[@]:i:chunk_size}" )

    subexpr='{"or": []}'
    for id in "${chunk[@]}"; do
        subexpr=$(echo "$subexpr" | jq --arg id "$id" \
          '.or += [{any:{in:{lhs:{splat:"dns.domains"},rhs:$id}}}]')
    done

    expr=$(echo "$expr" | jq --argjson s "$subexpr" '.or += [$s]')
done


json_data=$(jq -n --arg PREFIX "$PREFIX" --argjson EX "$expr" \
  '{name:$PREFIX,conditions:[{type:"traffic",expression:$EX}],action:"block",enabled:true,filters:["dns"]}')

policy_id=$(echo "$current_policies" | jq -r --arg PREFIX "$PREFIX" '.result|map(select(.name==$PREFIX))|.[0].id')

if [[ "$policy_id" == "null" || -z "$policy_id" ]]; then
    echo "Creating policy..."
    curl -sSfL -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/rules" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" --data "$json_data" \
      || error "Policy create failed"
else
    echo "Updating policy..."
    curl -sSfL -X PUT "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/rules/$policy_id" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" --data "$json_data" \
      || error "Policy update failed"
fi

### REMOVE UNUSED LISTS
for list_id in "${excess_list_ids[@]}"; do
    echo "Deleting unused list $list_id"
    curl -sSfL -X DELETE I am running a few minutes late; my previous meeting is running over.
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$list_id" \
      -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" > /dev/null
done
