#!/usr/bin/env bash
# Entregavel do video (etapa 5): "Envie manualmente varias mensagens para a
# fila SQS". E uma demonstracao DIFERENTE da carga no /evaluate -- aqui nada
# passa pela aplicacao, as mensagens vao direto para a fila pela AWS CLI, e o
# analytics-service escala por conta do backlog que elas criam.
#
#   bash scripts/sqs-send-manual.sh                 # 90s com 6 remetentes
#   DURATION=30 PARALLEL=2 bash scripts/sqs-send-manual.sh
#
# O corpo da mensagem precisa ter EXATAMENTE as 4 chaves que o
# analytics-service le em process_message (app.py): user_id, flag_name, result
# e timestamp. Faltando uma, o put_item no DynamoDB nunca acontece, a mensagem
# nao e apagada da fila e vira uma poison pill girando para sempre.
#
# `result` tem de ser booleano JSON (true/false), nao a string "true": o campo
# vai para o DynamoDB como {'BOOL': ...} e o boto3 recusa qualquer outro tipo.
set -euo pipefail

QUEUE_URL="${QUEUE_URL:-$(aws sqs get-queue-url --queue-name togglemaster-events --output text)}"
DURATION="${DURATION:-90}"            # segundos de envio
PARALLEL="${PARALLEL:-6}"             # remetentes simultaneos
FLAG_NAME="${FLAG_NAME:-manual-sqs-demo}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# flag_name proprio de proposito: deixa os eventos manuais distinguiveis dos
# que vieram do /evaluate quando a gente consultar o DynamoDB depois.
echo "Fila:     $QUEUE_URL"
echo "Flag:     $FLAG_NAME"
echo "Enviando por ${DURATION}s com ${PARALLEL} remetentes em paralelo..."
echo

# Monta um arquivo com 10 entradas (o maximo de um send-message-batch).
# O MessageBody e uma STRING JSON dentro de outro JSON, por isso o $q: ele
# guarda a sequencia \" literal, que escapa as aspas do corpo interno.
montar_lote() {
    local prefixo="$1" arquivo="$2" ts i body
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local q='\"'
    {
        printf '['
        for i in $(seq 0 9); do
            [ "$i" -gt 0 ] && printf ','
            body="{${q}user_id${q}:${q}${prefixo}-${i}${q}"
            body="${body},${q}flag_name${q}:${q}${FLAG_NAME}${q}"
            body="${body},${q}result${q}:true"
            body="${body},${q}timestamp${q}:${q}${ts}${q}}"
            printf '{"Id":"m%s","MessageBody":"%s"}' "$i" "$body"
        done
        printf ']'
    } > "$arquivo"
}

remetente() {
    local id="$1" fim="$2" lote=0 arquivo="$TMP/lote-$1.json"
    while [ "$(date +%s)" -lt "$fim" ]; do
        lote=$((lote + 1))
        montar_lote "manual-r${id}-l${lote}" "$arquivo"
        aws sqs send-message-batch \
            --queue-url "$QUEUE_URL" \
            --entries "file://$arquivo" >/dev/null
    done
    echo "  remetente $id: $lote lotes = $((lote * 10)) mensagens"
}

fim=$(( $(date +%s) + DURATION ))
for r in $(seq 1 "$PARALLEL"); do
    remetente "$r" "$fim" &
done
wait

echo
echo "Profundidade da fila agora (ja descontando o que o worker consumiu):"
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes' --output table

echo
echo "Para conferir que estas mensagens viraram itens no DynamoDB:"
echo "  aws dynamodb scan --table-name ToggleMasterAnalytics --select COUNT \\"
echo "    --filter-expression 'flag_name = :f' \\"
echo "    --expression-attribute-values '{\":f\":{\"S\":\"${FLAG_NAME}\"}}' \\"
echo "    --query Count"
