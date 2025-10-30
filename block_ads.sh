#!/bin/bash

API_TOKEN="$API_TOKEN"
ACCOUNT_ID="$ACCOUNT_ID"
PREFIX="Block ads"
MAX_LIST_SIZE=1000
MAX_LISTS=100
MAX_RETRIES=10

error() { echo "Error: $1"; rm -f 1hosts_lite_domains.wildcards.txt.*; exit 1; }
silent_error() { echo "Silent error: $1"; rm -f 1hosts_lite_domains.wildcards.txt.*; exit 0; }

# Download 1Hosts Lite
echo "Downloading 1Hosts Lite list..."
curl -sSfL --retry "$MAX_RETRIES" --retry-all-errors \
  https://raw.githubusercontent.com/badmojr/1Hosts/master/Lite/domains.wildcards \
  | grep -vE '^\s*(#|$)' > 1hosts_lite_domains.wildcards.txt || silent_error "Download failed"

git diff --exit-code 1hosts_lite_domains.wildcards.txt &>/dev/null && silent_error "No changes"
[[ -s 1hosts_lite_domains.wildcards.txt ]] || error "List empty"

total_lines=$(wc -l < 1hosts_lite_domains.wildcards.txt)
(( total_lines <= MAX_LIST_SIZE * MAX_LISTS )) || error "Too many domains"

# Get current lists and policies
current_lists=$(curl -sSfL -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
  -H "Authorization: Bearer ${API_TOKEN}") || error "Lists fetch failed"

current_policies=$(curl -sSfL -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
  -H "Authorization: Bearer ${API_TOKEN}") || error "Policies fetch failed"

# Split into chunks
split -l ${MAX_LIST_SIZE} 1hosts_lite_domains.wildcards.txt 1hosts_lite_domains.wildcards.txt.
chunked_lists=($(ls 1hosts_lite_domains.wildcards.txt.*))
used_list_ids=()
excess_list_ids=()
list_counter=1

existing_list_ids=$(echo "$current_lists" | jq -r --arg PREFIX "$PREFIX" '.result | map(select(.name|contains($PREFIX))) | .[].id')

# Update existing lists
for list_id in $existing_list_ids; do
    if [[ ${#chunked_lists[@]} -eq 0 ]]; then
        excess_list_ids+=("$list_id")
        continue
    fi

    file="${chunked_lists[0]}"
    new_items=$(jq -R -s 'split("\n")|map(select(length>0)|{"value":.})' "$file")

    payload=$(jq -n --argjson items "$new_items" '{append:$items,remove:[]}')
    curl -sSfL -X PATCH \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${list_id}" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$payload" || error "List update failed"

    used_list_ids+=("$list_id")
    rm -f "$file"
    chunked_lists=("${chunked_lists[@]:1}")
    list_counter=$((list_counter+1))
done

# Create new lists
for file in "${chunked_lists[@]}"; do
    formatted=$(printf "%03d" "$list_counter")
    items=$(jq -R -s 'split("\n")|map(select(length>0)|{"value":.})' "$file")

    payload=$(jq -n --arg name "${PREFIX} - ${formatted}" --argjson items "$items" '{name:$name,type:"DOMAIN",items:$items}')

    created=$(curl -sSfL -X POST \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" --data "$payload") || error "List create failed"

    used_list_ids+=("$(echo "$created" | jq -r '.result.id')")
    rm -f "$file"
    list_counter=$((list_counter+1))
done

# Build expression
if [[ ${#used_list_ids[@]} -eq 1 ]]; then
    expr="dns.domains[*] in {\"id\":\"${used_list_ids[0]}\"}"
else
    expr=$(printf "dns.domains[*] in {\"id\":\"%s\"} or " "${used_list_ids[@]}")
    expr="${expr% or }"
fi

# DNS rule JSON
json_dns=$(jq -n --arg name "$PREFIX" --arg expr "$expr" \
  '{name:$name,action:"block",enabled:true,filters:["dns"],expression:$expr}')

# HTTP rule JSON
json_http=$(jq -n --arg name "$PREFIX - HTTP" --arg expr "$expr" \
  '{name:$name,action:"block",enabled:true,filters:["http"],expression:$expr}')

# Update or create DNS policy
dns_id=$(echo "$current_policies" | jq -r --arg PREFIX "$PREFIX" '.result|map(select(.name==$PREFIX))|.[0].id')
if [[ -z "$dns_id" || "$dns_id" == "null" ]]; then
    curl -sSfL -X POST \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_dns"
else
    curl -sSfL -X PUT \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${dns_id}" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_dns"
fi

# Refresh to get latest policy list
current_policies=$(curl -sSfL -X GET \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
  -H "Authorization: Bearer ${API_TOKEN}")

# Update or create HTTP policy
http_id=$(echo "$current_policies" | jq -r --arg PREFIX "$PREFIX - HTTP" '.result|map(select(.name==$PREFIX))|.[0].id')
if [[ -z "$http_id" || "$http_id" == "null" ]]; then
    curl -sSfL -X POST \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_http"
else
    curl -sSfL -X PUT \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/rules/${http_id}" \
      -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "$json_http"
fi

# Delete excess lists
for id in "${excess_list_ids[@]}"; do
    curl -sSfL -X DELETE \
      "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/gateway/lists/${id}" \
      -H "Authorization: Bearer ${API_TOKEN}"
done

# Git commit
git config --global user.email "${GITHUB_ACTOR_ID}+${GITHUB_ACTOR}@users.noreply.github.com"
git config --global user.name "$(gh api /users/${GITHUB_ACTOR} | jq .name -r)"
git add 1hosts_lite_domains.wildcards.txt
git commit -m "Update 1Hosts Lite list" --author=.
git push origin main
