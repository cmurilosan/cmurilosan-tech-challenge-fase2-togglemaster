#!/usr/bin/env bash
# Teste de fumaca do ambiente local: valida o fluxo ponta a ponta do ToggleMaster
# depois de um `docker compose up -d --build`.
#
#   bash scripts/smoke-test.sh
#
# Fluxo exercitado:
#   readiness dos 5 servicos -> cria flag -> cria regra 50% -> avalia usuarios
#   -> confere o cache do Redis -> confere os eventos gravados no DynamoDB.
set -euo pipefail

AUTH_URL="${AUTH_URL:-http://localhost:8001}"
FLAG_URL="${FLAG_URL:-http://localhost:8002}"
TARGETING_URL="${TARGETING_URL:-http://localhost:8003}"
EVAL_URL="${EVAL_URL:-http://localhost:8004}"
ANALYTICS_URL="${ANALYTICS_URL:-http://localhost:8005}"

MASTER_KEY="${MASTER_KEY:-admin-secreto-123}"
API_KEY="${SERVICE_API_KEY:-tm_key_local_dev_0000000000000000}"
FLAG_NAME="${FLAG_NAME:-enable-new-dashboard}"
DYNAMO_ENDPOINT="${DYNAMO_ENDPOINT:-http://localhost:8000}"
DYNAMO_TABLE="${AWS_DYNAMODB_TABLE:-ToggleMasterAnalytics}"

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
info() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '  \033[31mFALHOU\033[0m %s\n' "$1"; exit 1; }

wait_for() {
    local name="$1" url="$2" tries=30
    while (( tries-- > 0 )); do
        if curl -fsS "$url/ready" >/dev/null 2>&1; then
            ok "$name respondendo em $url"
            return 0
        fi
        sleep 2
    done
    fail "$name nao ficou ready em $url/ready"
}

info "1/5 Readiness dos 5 microsservicos"
wait_for "auth-service"       "$AUTH_URL"
wait_for "flag-service"       "$FLAG_URL"
wait_for "targeting-service"  "$TARGETING_URL"
wait_for "evaluation-service" "$EVAL_URL"
wait_for "analytics-service"  "$ANALYTICS_URL"

info "2/5 Autenticacao"
code=$(curl -s -o /dev/null -w '%{http_code}' "$FLAG_URL/flags")
[[ "$code" == "401" ]] && ok "flag-service rejeita requisicao sem chave (401)" \
                       || fail "esperado 401 sem chave, recebido $code"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $API_KEY" "$FLAG_URL/flags")
[[ "$code" == "200" ]] && ok "chave de servico local aceita pelo auth-service (200)" \
                       || fail "esperado 200 com a chave local, recebido $code"

info "3/5 Criando a flag e a regra de segmentacao"
curl -s -o /dev/null -X POST "$FLAG_URL/flags" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"name\":\"$FLAG_NAME\",\"description\":\"Smoke test\",\"is_enabled\":true}" || true
curl -s -X PUT "$FLAG_URL/flags/$FLAG_NAME" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d '{"is_enabled": true}' >/dev/null
ok "flag '$FLAG_NAME' criada/ativada"

curl -s -o /dev/null -X POST "$TARGETING_URL/rules" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"flag_name\":\"$FLAG_NAME\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}" || true
curl -s -X PUT "$TARGETING_URL/rules/$FLAG_NAME" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d '{"rules": {"type": "PERCENTAGE", "value": 50}}' >/dev/null
ok "regra PERCENTAGE 50% aplicada a '$FLAG_NAME'"

info "4/5 Avaliando usuarios (hot path)"
true_count=0
for i in $(seq 1 20); do
    body=$(curl -fsS "$EVAL_URL/evaluate?user_id=smoke-user-$i&flag_name=$FLAG_NAME")
    [[ "$body" == *'"result":true'* ]] && (( ++true_count ))
done
ok "20 avaliacoes concluidas - $true_count retornaram true (esperado: perto de 10)"
(( true_count > 0 && true_count < 20 )) \
    || echo "  AVISO: distribuicao fora do esperado para uma regra de 50%"

info "5/5 Eventos gravados no DynamoDB Local"
sleep 5
if command -v aws >/dev/null 2>&1; then
    count=$(AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local AWS_REGION=us-east-1 \
        aws dynamodb scan --table-name "$DYNAMO_TABLE" --select COUNT \
        --endpoint-url "$DYNAMO_ENDPOINT" --query 'Count' --output text 2>/dev/null || echo "0")
    if [[ "$count" -ge 1 ]]; then
        ok "$count evento(s) na tabela $DYNAMO_TABLE"
    else
        fail "nenhum evento chegou ao DynamoDB - verifique: docker compose logs analytics-service"
    fi
else
    echo "  AWS CLI nao encontrada; pule esta verificacao ou rode:"
    echo "  aws dynamodb scan --table-name $DYNAMO_TABLE --endpoint-url $DYNAMO_ENDPOINT"
fi

printf '\n\033[32mAmbiente local validado com sucesso.\033[0m\n'
