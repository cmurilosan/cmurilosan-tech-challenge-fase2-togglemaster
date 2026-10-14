#!/bin/sh
# Cria a tabela do analytics-service no DynamoDB Local (job efemero do compose).
# Idempotente: se a tabela ja existe, nao faz nada.
set -e

TABLE="${AWS_DYNAMODB_TABLE:-ToggleMasterAnalytics}"
ENDPOINT="${AWS_DYNAMODB_ENDPOINT:-http://dynamodb-local:8000}"

echo "aguardando o DynamoDB Local em ${ENDPOINT} ..."
until aws dynamodb list-tables --endpoint-url "$ENDPOINT" >/dev/null 2>&1; do
    sleep 2
done

if aws dynamodb describe-table --table-name "$TABLE" --endpoint-url "$ENDPOINT" >/dev/null 2>&1; then
    echo "tabela ${TABLE} ja existe."
    exit 0
fi

aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=event_id,AttributeType=S \
    --key-schema AttributeName=event_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --endpoint-url "$ENDPOINT" >/dev/null

echo "tabela ${TABLE} criada com sucesso."
