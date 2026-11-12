#!/bin/bash
# Aplica um .sql no Supabase da Isa (schema portaria) via Management API. Uso: sql/apply.sh arquivo.sql | -q "select 1"
set -e
ENV=~/projetos/isa/.env
TOKEN=$(grep '^SUPABASE_ACCESS_TOKEN=' $ENV | cut -d= -f2-)
URL=$(grep '^SUPABASE_URL=' $ENV | cut -d= -f2-)
REF=$(echo "$URL" | sed -E 's#https://([^.]+)\..*#\1#')
if [ "$1" = "-q" ]; then Q="$2"; else Q=$(cat "$1"); fi
python3 -c 'import json,sys;print(json.dumps({"query":sys.argv[1]}))' "$Q" | \
 curl -s -X POST "https://api.supabase.com/v1/projects/$REF/database/query" \
 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d @-
echo
