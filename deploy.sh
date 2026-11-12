#!/bin/bash
# Publica a Edge Function portaria-api no Supabase da Isa (usa os segredos que o projeto já tem).
set -e; cd "$(dirname "$0")"
ENV=~/projetos/isa/.env
TOKEN=$(grep '^SUPABASE_ACCESS_TOKEN=' $ENV | cut -d= -f2-); URL=$(grep '^SUPABASE_URL=' $ENV | cut -d= -f2-)
REF=$(echo $URL | sed -E 's#https://([^.]+)\..*#\1#')
curl -s -X POST "https://api.supabase.com/v1/projects/$REF/functions/deploy?slug=portaria-api" -H "Authorization: Bearer $TOKEN" \
 -F 'metadata={"entrypoint_path":"index.ts","name":"portaria-api","verify_jwt":false};type=application/json' \
 -F 'file=@supabase/functions/portaria-api/index.ts;filename=index.ts' | head -c 300; echo
