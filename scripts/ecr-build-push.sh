#!/usr/bin/env bash
# Etapa 2 - cria os 5 repositorios no ECR (se nao existirem), compila as
# imagens e publica.
#
#   AWS_REGION=us-east-1 IMAGE_TAG=v1 bash scripts/ecr-build-push.sh
#
# As imagens sao compiladas para linux/amd64 explicitamente: os nos do EKS sao
# t3.medium (amd64) e um build feito em maquina ARM geraria um ExecFormatError
# dificil de diagnosticar no cluster.
set -euo pipefail

cd "$(dirname "$0")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
SERVICES=(auth-service flag-service targeting-service evaluation-service analytics-service)

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Conta ${ACCOUNT_ID} / regiao ${AWS_REGION} / tag ${IMAGE_TAG}"

echo "==> Garantindo os repositorios no ECR"
for s in "${SERVICES[@]}"; do
    if aws ecr describe-repositories --repository-names "togglemaster/$s" \
            --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "    togglemaster/$s (ja existe)"
    else
        aws ecr create-repository \
            --repository-name "togglemaster/$s" \
            --image-scanning-configuration scanOnPush=true \
            --region "$AWS_REGION" >/dev/null
        echo "    togglemaster/$s (criado)"
    fi
done

echo "==> Login no ECR"
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY"

for s in "${SERVICES[@]}"; do
    image="${REGISTRY}/togglemaster/${s}:${IMAGE_TAG}"
    echo "==> build  ${s}"
    docker build --platform linux/amd64 -t "$image" "./${s}"
    echo "==> push   ${s}"
    docker push "$image"
done

echo
echo "Imagens publicadas. Use este registry na linha image: dos manifestos:"
echo "  ${REGISTRY}/togglemaster/<servico>:${IMAGE_TAG}"
