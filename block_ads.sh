#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_RETRIES=10

error() { echo "Error: $1"; rm -f oisd_big_domainswild2.txt.*; exit 1; }
silent_error() { echo "$1"; rm -f oisd_big_domainswild2.txt.*; exit 0; }

echo "Downloading list..."
curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors \
 https://raw.githubusercontent.com/sjhgvr/oisd/main/domainswild2_big.txt \
 | grep -vE '^\s*(#|$)' > oisd_big_domainswild2.txt || silent_error "Download failed"

[[ -s oisd_big_domainswild2.txt ]] || error "Downloaded list empty"

if [[ -f oisd_big_domainswild2.txt.old ]]; then
    cmp -s oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old && silent_error "No changes"
fi

echo "Deduping..."
sort -u oisd_big_domainswild2.txt -o oisd_big_domainswild2.txt
cp oisd_big_domainswild2.txt oisd_big_domainswild2.txt.old

split -l $MAX_LIST_SIZE oisd_big_domainswild2.txt oisd_big_domainswild2.txt. || error "Split failed"
chunks=(oisd_big_domainswild2.txt.*)

echo "Fetching Cloudflare lists..."
lists=$(curl -sSfL -X GET \
 "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists" \
 -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json") || error "List fetch failed"

existing_ids=($(echo "$lists" | jq -r --arg PREFIX "$PREFIX" '
 .result|map(select(.name|startswith($PREFIX)))|sort_by(.name)|.[].id'))

max_index=$(echo "$lists" | jq -r --arg PREFIX "$PREFIX" '
 .result|map(select(.name|startswith($PREFIX)))
 | map(.name|capture(".* - (?<n>[0-9]+)$").n|tonumber)
 | max // 0')

next_index=$((max_index + 1))

echo "Fetching policy..."
policy=$(curl -sSfL -X GET \
 "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/rules" \
 -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json")

policy_id=$(echo "$policy" | jq -r --arg PREFIX "$PREFIX" '.result|map(select(.name==$PREFIX))|.[0].id')

if [[ "$policy_id" == "null" || -z "$policy_id" ]]; then
  echo "Creating policy..."
  create_payload=$(jq -n --arg PREFIX "$PREFIX" \
   '{name:$PREFIX,conditions:[{type:"traffic",expression:{or:[]}}],action:"block",enabled:true,filters:["dns"]}')
  policy=$(curl -sSfL -X POST \
   "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/rules" \
   -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
   --data "$create_payload") || error "Policy create failed"
  policy_id=$(echo "$policy" | jq -r '.result.id')
fi

update_rule() {
  list_id="$1"
  echo "Linking $list_id to DNS rule"
  policy=$(curl -sSfL -X GET \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/rules" \
    -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json")

  expr=$(echo "$policy" | jq --arg PREFIX "$PREFIX" \
    '.result|map(select(.name==$PREFIX))|.[0].conditions[0].expression')

  new_expr=$(jq -n --argjson old "$expr" --arg id "$list_id" \
    '{ or: [ $old, { any:{ in:{ lhs:{splat:"dns.domains"}, rhs:$id }}} ] }')

  json_data=$(jq -n --arg PREFIX "$PREFIX" --argjson EX "$new_expr" \
    '{name:$PREFIX,conditions:[{type:"traffic",expression:$EX}],action:"block",enabled:true,filters:["dns"]}')

  curl -sSfL -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/rules/$policy_id" \
    -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
    --data "$json_data" \
    || error "Policy update failed"
}

used=()
excess=()

# UPDATE EXISTING LISTS
for list_id in "${existing_ids[@]}"; do
  if [[ ${#chunks[@]} -eq 0 ]]; then
    excess+=("$list_id")
    continue
  fi

  echo "Checking $list_id..."
  remote=$(curl -sSfL -X GET \
   "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$list_id/items" \
   -H "Authorization: Bearer $API_TOKEN" | jq -r '.result[].value' | sort)

  local_sorted=$(sort "${chunks[0]}")

  if cmp -s <(echo "$remote") <(echo "$local_sorted"); then
    echo "Skip (unchanged)"
    used+=("$list_id")
    rm -f "${chunks[0]}"
    chunks=("${chunks[@]:1}")
    update_rule "$list_id"
    continue
  fi

  echo "Updating $list_id..."
  name=$(echo "$lists" | jq -r --arg id "$list_id" '.result[]|select(.id==$id).name')
  items=$(jq -R -s 'split("\n")|map(select(length>0)|{value:.})' "${chunks[0]}")
  payload=$(jq -n --arg NAME "$name" --argjson items "$items" '{name:$NAME,type:"DOMAIN",items:$items}')

  curl -sSfL -X PUT \
   "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$list_id" \
   -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
   --data "$payload" || error "Update failed"

  used+=("$list_id")
  rm -f "${chunks[0]}"
  chunks=("${chunks[@]:1}")
  update_rule "$list_id"
done

# CREATE NEW LISTS
for file in "${chunks[@]}"; do
  formatted=$(printf "%03d" "$next_index")
  echo "Creating ${PREFIX} - ${formatted}"

  items=$(jq -R -s 'split("\n")|map(select(length>0)|{value:.})' "$file")
  payload=$(jq -n --arg NAME "${PREFIX} - ${formatted}" --argjson items "$items" '{name:$NAME,type:"DOMAIN",items:$items}')

  result=$(curl -sSfL -X POST \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists" \
    -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
    --data "$payload") || error "Create failed"

  list_id=$(echo "$result" | jq -r '.result.id')
  used+=("$list_id")
  rm -f "$file"
  update_rule "$list_id"
  next_index=$((next_index + 1))
done

# DELETE UNUSED LISTS
for list_id in "${excess[@]}"; do
  echo "Deleting unused list $list_id"
  curl -sSfL -X DELETE \
   "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/gateway/lists/$list_id" \
   -H "Authorization: Bearer $API_TOKEN" >/dev/null
done
