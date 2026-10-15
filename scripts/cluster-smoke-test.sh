#!/usr/bin/env bash
# Teste de fumaca do ambiente no EKS: valida o fluxo ponta a ponta atraves do
# Ingress (etapa 4) e confere os eventos no DynamoDB real.
#
#   BASE_URL=http://<dns-do-elb> MASTER_KEY=... bash scripts/cluster-smoke-test.sh
#
# Se SERVICE_API_KEY nao for passada, o script emite uma chave nova pelo
# auth-service (POST /admin/keys com a MASTER_KEY) e imprime o valor no fim --
# e essa chave que vai para o SERVICE_API_KEY do k8s/02-secret.yaml.
#
# Fluxo: 401 sem chave -> emite chave -> cria flag -> cria regra 50% ->
# avalia 20 usuarios -> conta os eventos no DynamoDB.
set -euo pipefail

BASE_URL="${BASE_URL:?defina BASE_URL com o DNS do ELB do Ingress}"
BASE_URL="${BASE_URL%/}"
MASTER_KEY="${MASTER_KEY:?defina MASTER_KEY (a mesma do k8s/02-secret.yaml)}"
API_KEY="${SERVICE_API_KEY:-}"
FLAG_NAME="${FLAG_NAME:-enable-new-dashboard}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DYNAMO_TABLE="${DYNAMODB_TABLE:-ToggleMasterAnalytics}"

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '  \033[31mFALHOU\033[0m %s\n' "$1"; exit 1; }

info "1/5 Ingress respondendo"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/flags")
[[ "$code" == "401" ]] && ok "flag-service pelo Ingress rejeita sem chave (401)" \
                       || fail "esperado 401 em $BASE_URL/flags, recebido $code"

info "2/5 Chave de API"
if [[ -z "$API_KEY" ]]; then
    resp=$(curl -fsS -X POST "$BASE_URL/admin/keys" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $MASTER_KEY" \
        -d '{"name":"service-key-eks"}')
    API_KEY=$(printf '%s' "$resp" | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ -n "$API_KEY" ]] || fail "nao consegui extrair a chave da resposta: $resp"
    ok "chave emitida pelo auth-service"
else
    ok "usando a SERVICE_API_KEY do ambiente"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $API_KEY" "$BASE_URL/flags")
[[ "$code" == "200" ]] && ok "chave aceita pelo auth-service (200)" \
                       || fail "esperado 200 com a chave, recebido $code"

info "3/5 Criando a flag e a regra de segmentacao"
curl -s -o /dev/null -X POST "$BASE_URL/flags" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
    -d "{\"name\":\"$FLAG_NAME\",\"description\":\"Smoke test EKS\",\"is_enabled\":true}" || true
curl -s -o /dev/null -X PUT "$BASE_URL/flags/$FLAG_NAME" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
    -d '{"is_enabled": true}'
ok "flag '$FLAG_NAME' criada/ativada"

curl -s -o /dev/null -X POST "$BASE_URL/rules" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
    -d "{\"flag_name\":\"$FLAG_NAME\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}" || true
curl -s -o /dev/null -X PUT "$BASE_URL/rules/$FLAG_NAME" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" \
    -d '{"rules": {"type": "PERCENTAGE", "value": 50}}'
ok "regra PERCENTAGE 50% aplicada a '$FLAG_NAME'"

info "4/5 Avaliando usuarios pelo caminho quente"
true_count=0
for i in $(seq 1 20); do
    body=$(curl -fsS "$BASE_URL/evaluate?user_id=eks-user-$i&flag_name=$FLAG_NAME")
    [[ "$body" == *'"result":true'* ]] && (( ++true_count )) || true
done
ok "20 avaliacoes concluidas - $true_count retornaram true (esperado: perto de 10)"
(( true_count > 0 && true_count < 20 )) \
    || echo "  AVISO: distribuicao fora do esperado para uma regra de 50%"

info "5/5 Eventos gravados no DynamoDB"
sleep 10
count=$(aws dynamodb scan --table-name "$DYNAMO_TABLE" --select COUNT \
    --region "$AWS_REGION" --query 'Count' --output text 2>/dev/null || echo "0")
if [[ "$count" -ge 1 ]]; then
    ok "$count evento(s) na tabela $DYNAMO_TABLE"
else
    fail "nenhum evento no DynamoDB - veja: kubectl -n togglemaster logs -l app=analytics-service"
fi

printf '\n\033[32mAmbiente no EKS validado com sucesso.\033[0m\n'
printf 'SERVICE_API_KEY=%s\n' "$API_KEY"
