#!/usr/bin/env bash
# Provisiona a infra inteira das etapas 2 a 4 numa sessao do AWS Academy, do
# zero ao smoke test, sem edicao manual de manifesto.
#
#   bash scripts/provision-aws.sh            # tudo (~15 min)
#   bash scripts/provision-aws.sh imds       # so corrige o hop limit do IMDS
#
# Por que ele existe: o Learner Lab destroi os recursos quando a sessao fecha,
# entao o provisionamento tem de ser refeito em toda sessao de gravacao. Feito
# a mao pelo runbook sao ~25 min de copia e cola; aqui o cluster sobe em
# paralelo com RDS/Redis e os manifestos sao preenchidos por sed.
#
# Idempotente: cada recurso e checado antes de criar, entao reexecutar depois
# de uma falha no meio e seguro.
#
# PLANO C (se os nos nao entrarem no cluster por deny de SCP no nodeadm):
#   K8S_VERSION=1.32 AMI_TYPE=AL2_x86_64 bash scripts/provision-aws.sh
# O AMI AL2 usa o bootstrap.sh antigo, que nao chama ec2:DescribeInstances.
set -euo pipefail

cd "$(dirname "$0")/.."

export AWS_PAGER=""
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION
CLUSTER_NAME="${CLUSTER_NAME:-togglemaster}"
NODEGROUP_NAME="${NODEGROUP_NAME:-ng-togglemaster}"
IMAGE_TAG="${IMAGE_TAG:-v1}"
PG_PASSWORD="${PG_PASSWORD:-TroqueEstaSenha123}"
K8S_VERSION="${K8S_VERSION:-}"          # vazio = versao default do EKS
AMI_TYPE="${AMI_TYPE:-AL2023_x86_64_STANDARD}"
METRICS_VERSION="${METRICS_VERSION:-v0.9.0}"
NGINX_VERSION="${NGINX_VERSION:-controller-v1.15.1}"

info() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33mAVISO\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFALHOU\033[0m %s\n' "$1"; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"

# --------------------------------------------------------------- hop limit
# Separado numa funcao porque a correcao e POR INSTANCIA e se perde toda vez
# que o Auto Scaling troca um no. Rode "provision-aws.sh imds" nesse caso.
fix_imds() {
    local ids id
    ids=$(aws ec2 describe-instances \
        --filters "Name=tag:eks:nodegroup-name,Values=${NODEGROUP_NAME}" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
    if [[ -z "$ids" ]]; then
        warn "nenhuma instancia do node group rodando"
        return 0
    fi
    for id in $ids; do
        aws ec2 modify-instance-metadata-options --instance-id "$id" \
            --http-put-response-hop-limit 2 --http-endpoint enabled >/dev/null
        ok "hop limit 2 em $id"
    done
}

if [[ "${1:-}" == "imds" ]]; then
    info "Corrigindo o hop limit do IMDS"
    fix_imds
    info "Reiniciando os servicos que usam a AWS"
    kubectl -n togglemaster rollout restart deploy/analytics-service deploy/evaluation-service
    exit 0
fi

info "Conta ${ACCOUNT_ID} / regiao ${AWS_REGION}"

# ------------------------------------------------------------------- rede
info "1. Rede (VPC default do lab)"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
    --query 'Vpcs[0].CidrBlock' --output text)
# us-east-1e nao e suportada pelo EKS.
SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" \
              Name=availability-zone,Values=us-east-1a,us-east-1b,us-east-1c,us-east-1d \
    --query 'Subnets[].SubnetId' --output text)
SUBNET_CSV=$(echo "$SUBNET_IDS" | tr '\t' ',' | tr ' ' ',')
ok "VPC $VPC_ID ($VPC_CIDR)"
ok "subnets $SUBNET_CSV"

# --------------------------------------------------------------- 2. ECR
info "2. ECR (repositorios + imagens ${IMAGE_TAG})"
if aws ecr describe-images --repository-name togglemaster/auth-service \
        --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
    ok "imagens ${IMAGE_TAG} ja publicadas, pulando o build"
else
    IMAGE_TAG="$IMAGE_TAG" bash scripts/ecr-build-push.sh
fi

# ------------------------------------------------- 3. EKS (dispara e segue)
info "3. EKS - criando o cluster (nao espera: RDS/Redis sobem em paralelo)"
if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    ok "cluster ${CLUSTER_NAME} ja existe"
else
    aws eks create-cluster \
        --name "$CLUSTER_NAME" \
        --role-arn "$LAB_ROLE_ARN" \
        ${K8S_VERSION:+--kubernetes-version "$K8S_VERSION"} \
        --resources-vpc-config subnetIds="$SUBNET_CSV",endpointPublicAccess=true \
        >/dev/null
    ok "create-cluster disparado"
fi

# ----------------------------------------------- 4 a 7. dados (em paralelo)
ensure_sg() {
    local name="$1" desc="$2" port="$3" sg
    sg=$(aws ec2 describe-security-groups \
        --filters Name=group-name,Values="$name" Name=vpc-id,Values="$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    if [[ "$sg" == "None" || -z "$sg" ]]; then
        sg=$(aws ec2 create-security-group --group-name "$name" \
            --description "$desc" --vpc-id "$VPC_ID" --query GroupId --output text)
        aws ec2 authorize-security-group-ingress --group-id "$sg" \
            --protocol tcp --port "$port" --cidr "$VPC_CIDR" >/dev/null
    fi
    echo "$sg"
}

info "4. RDS - 3 instancias PostgreSQL"
RDS_SG=$(ensure_sg togglemaster-rds "PostgreSQL do ToggleMaster, acesso interno a VPC" 5432)
ok "security group $RDS_SG"
for db in auth flags targeting; do
    if aws rds describe-db-instances --db-instance-identifier "togglemaster-${db}" \
            >/dev/null 2>&1; then
        ok "togglemaster-${db} ja existe"
    else
        # Sem --engine-version de proposito: o default atual do RDS nao
        # envelhece o script (deu PostgreSQL 18.3 em 2026-11-01).
        aws rds create-db-instance \
            --db-instance-identifier "togglemaster-${db}" \
            --db-name "${db}_db" \
            --engine postgres \
            --db-instance-class db.t3.micro --allocated-storage 20 \
            --master-username togglemaster --master-user-password "$PG_PASSWORD" \
            --vpc-security-group-ids "$RDS_SG" \
            --no-publicly-accessible --no-multi-az --backup-retention-period 0 \
            >/dev/null
        ok "togglemaster-${db} criado"
    fi
done

info "5. ElastiCache - Redis"
REDIS_SG=$(ensure_sg togglemaster-redis "Redis do ToggleMaster, acesso interno a VPC" 6379)
ok "security group $REDIS_SG"
if ! aws elasticache describe-cache-subnet-groups \
        --cache-subnet-group-name togglemaster >/dev/null 2>&1; then
    aws elasticache create-cache-subnet-group \
        --cache-subnet-group-name togglemaster \
        --cache-subnet-group-description "Subnets do ToggleMaster" \
        --subnet-ids $SUBNET_IDS >/dev/null
fi
if aws elasticache describe-cache-clusters --cache-cluster-id togglemaster-redis \
        >/dev/null 2>&1; then
    ok "togglemaster-redis ja existe"
else
    aws elasticache create-cache-cluster \
        --cache-cluster-id togglemaster-redis \
        --engine redis --cache-node-type cache.t3.micro --num-cache-nodes 1 \
        --cache-subnet-group-name togglemaster \
        --security-group-ids "$REDIS_SG" >/dev/null
    ok "togglemaster-redis criado"
fi

info "6. DynamoDB"
if aws dynamodb describe-table --table-name ToggleMasterAnalytics >/dev/null 2>&1; then
    ok "ToggleMasterAnalytics ja existe"
else
    aws dynamodb create-table \
        --table-name ToggleMasterAnalytics \
        --attribute-definitions AttributeName=event_id,AttributeType=S \
        --key-schema AttributeName=event_id,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST >/dev/null
    aws dynamodb wait table-exists --table-name ToggleMasterAnalytics
    ok "ToggleMasterAnalytics criada"
fi

info "7. SQS"
if ! SQS_URL=$(aws sqs get-queue-url --queue-name togglemaster-events \
        --output text 2>/dev/null); then
    SQS_URL=$(aws sqs create-queue --queue-name togglemaster-events \
        --attributes VisibilityTimeout=60,ReceiveMessageWaitTimeSeconds=20 \
        --query QueueUrl --output text)
fi
ok "fila $SQS_URL"

# ------------------------------------------------------- esperas e endpoints
info "Esperando o cluster EKS ficar ACTIVE (~10 min)"
aws eks wait cluster-active --name "$CLUSTER_NAME"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
ok "cluster ACTIVE, kubeconfig atualizado"

info "3b. Node group"
if aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP_NAME" >/dev/null 2>&1; then
    ok "${NODEGROUP_NAME} ja existe"
else
    aws eks create-nodegroup \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP_NAME" \
        --node-role "$LAB_ROLE_ARN" \
        --subnets $SUBNET_IDS \
        --instance-types t3.medium \
        --ami-type "$AMI_TYPE" \
        --disk-size 20 \
        --scaling-config minSize=2,maxSize=4,desiredSize=2 >/dev/null
    ok "create-nodegroup disparado"
fi
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME"
ok "node group ACTIVE"

info "3c. Hop limit do IMDS (sem isso os pods nao pegam credencial)"
fix_imds

info "Confirmando que os nos entraram no cluster"
for _ in $(seq 1 24); do
    n=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "$n" -ge 2 ]]; then
        break
    fi
    sleep 15
done
if [[ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -lt 2 ]]; then
    fail "os nos nao registraram. Veja o boot de um deles com:
    aws ec2 get-console-output --instance-id <id> --output text | grep -i denied
  Se houver deny de SCP no ec2:DescribeInstances, rode o PLANO C:
    K8S_VERSION=1.32 AMI_TYPE=AL2_x86_64 bash scripts/provision-aws.sh"
fi
kubectl get nodes
ok "nos registrados"

info "Esperando RDS e Redis"
for db in auth flags targeting; do
    aws rds wait db-instance-available --db-instance-identifier "togglemaster-${db}"
    ok "togglemaster-${db} available"
done
aws elasticache wait cache-cluster-available --cache-cluster-id togglemaster-redis
ok "togglemaster-redis available"

RDS_AUTH=$(aws rds describe-db-instances --db-instance-identifier togglemaster-auth \
    --query 'DBInstances[0].Endpoint.Address' --output text)
RDS_FLAGS=$(aws rds describe-db-instances --db-instance-identifier togglemaster-flags \
    --query 'DBInstances[0].Endpoint.Address' --output text)
RDS_TARGETING=$(aws rds describe-db-instances --db-instance-identifier togglemaster-targeting \
    --query 'DBInstances[0].Endpoint.Address' --output text)
REDIS_HOST=$(aws elasticache describe-cache-clusters --cache-cluster-id togglemaster-redis \
    --show-cache-node-info \
    --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' --output text)

# ------------------------------------------------------------- 8. add-ons
info "8. Metrics Server e Nginx Ingress Controller"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_VERSION}/components.yaml"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s
ok "metrics-server pronto"

kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${NGINX_VERSION}/deploy/static/provider/aws/deploy.yaml"
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s
ok "ingress-nginx pronto (o webhook de admissao ja responde)"

INGRESS_HOST=""
for _ in $(seq 1 30); do
    INGRESS_HOST=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n "$INGRESS_HOST" ]]; then
        break
    fi
    sleep 10
done
if [[ -z "$INGRESS_HOST" ]]; then
    fail "o NLB do Ingress nao recebeu hostname"
fi
ok "NLB $INGRESS_HOST"

# ------------------------------------------- 9. manifestos preenchidos
info "9. Preenchendo os manifestos com os valores desta sessao"
# Numa reexecucao, reaproveita a MASTER_KEY que ja esta no cluster. Gerar uma
# nova sem reiniciar o auth-service deixaria o pod com a chave antiga em
# memoria e o smoke test tomaria 401 em POST /admin/keys.
MASTER_KEY_NO_CLUSTER=$(kubectl -n togglemaster get secret togglemaster-secrets \
    -o jsonpath='{.data.MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [[ -n "$MASTER_KEY_NO_CLUSTER" ]]; then
    MASTER_KEY="${MASTER_KEY:-$MASTER_KEY_NO_CLUSTER}"
    ok "reaproveitando a MASTER_KEY que ja esta no cluster"
else
    MASTER_KEY="${MASTER_KEY:-$(openssl rand -hex 24)}"
fi

sed -i \
    -e "s|^\(  AWS_SQS_URL: \).*|\1\"${SQS_URL}\"|" \
    -e "s|^\(  REDIS_URL: \).*|\1\"redis://${REDIS_HOST}:6379\"|" \
    k8s/01-configmap.yaml

pg_url() { echo "postgres://togglemaster:${PG_PASSWORD}@${1}:5432/${2}?sslmode=require"; }
sed -i \
    -e "s|^\(  DATABASE_URL_AUTH: \).*|\1\"$(pg_url "$RDS_AUTH" auth_db)\"|" \
    -e "s|^\(  DATABASE_URL_FLAGS: \).*|\1\"$(pg_url "$RDS_FLAGS" flags_db)\"|" \
    -e "s|^\(  DATABASE_URL_TARGETING: \).*|\1\"$(pg_url "$RDS_TARGETING" targeting_db)\"|" \
    -e "s|^\(  MASTER_KEY: \).*|\1\"${MASTER_KEY}\"|" \
    k8s/02-secret.yaml

# O ID da conta muda de sessao para sessao no Academy. Os dois padroes cobrem
# os dois estados do arquivo: o placeholder recem-restaurado do Git e um ID de
# conta de uma execucao anterior (reexecucao idempotente).
sed -i \
    -e "s|TROQUE-ACCOUNT-ID\.dkr\.ecr\.|${ACCOUNT_ID}.dkr.ecr.|g" \
    -e "s|[0-9]\{12\}\.dkr\.ecr\.|${ACCOUNT_ID}.dkr.ecr.|g" \
    k8s/1*.yaml
ok "configmap, secret e as 5 linhas image: preenchidos"

info "Aplicando os manifestos"
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/

info "Schema dos bancos"
kubectl -n togglemaster create configmap togglemaster-db-schemas \
    --from-file=auth.sql=auth-service/db/init.sql \
    --from-file=flags.sql=flag-service/db/init.sql \
    --from-file=targeting.sql=targeting-service/db/init.sql \
    --dry-run=client -o yaml | kubectl apply -f -
# O apply do diretorio acima ja criou o Job com o configmap ainda ausente, e um
# Job e imutavel: recria com o configmap no lugar.
kubectl -n togglemaster delete job db-init --ignore-not-found >/dev/null
kubectl apply -f k8s/90-db-init-job.yaml
kubectl -n togglemaster wait --for=condition=complete job/db-init --timeout=180s
ok "schema aplicado"

# ------------------------------------------------- smoke test e chave real
# A AWS atribui o hostname do NLB antes de o balanceador comecar a atender
# (~2 a 3 min). Esperar so o hostname, como esta no passo 8, nao basta: o
# smoke test bate num DNS frio, recebe 000 e o set -e aborta o script. Esta
# espera fica aqui, e nao no passo 8, para correr em paralelo com o apply dos
# manifestos e o Job do schema.
info "Esperando o NLB comecar a atender"
nlb_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${INGRESS_HOST}/flags" 2>/dev/null || echo "000"
}
for _ in $(seq 1 36); do
    code=$(nlb_code)
    if [[ "$code" != "000" ]]; then
        ok "NLB atendendo (HTTP ${code})"
        break
    fi
    sleep 10
done
if [[ "$(nlb_code)" == "000" ]]; then
    fail "o NLB nao atendeu em 6 min. Confira com:
    kubectl -n ingress-nginx get svc ingress-nginx-controller
    curl -v http://${INGRESS_HOST}/flags"
fi

# A chave de servico tem de estar NO POD antes do smoke test. O passo 4 dele
# chama /evaluate, e o evaluation-service usa a SERVICE_API_KEY para falar com
# o flag-service; com o placeholder ele toma 401 e o Ingress devolve 502. O
# runbook (passo 9) descreve a ordem inversa -- smoke test primeiro, chave
# depois -- e por isso nunca fecha 5/5 numa infra recem-criada.
info "Emitindo a chave de servico no auth-service"
KEY_RESP=$(curl -fsS -X POST "http://${INGRESS_HOST}/admin/keys" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -d '{"name":"service-key-eks"}')
SERVICE_API_KEY=$(printf '%s' "$KEY_RESP" \
    | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$SERVICE_API_KEY" ]]; then
    fail "nao consegui extrair a chave da resposta do auth-service"
fi
ok "chave emitida"

info "Aplicando a chave e reiniciando o evaluation-service"
sed -i "s|^\(  SERVICE_API_KEY: \).*|\1\"${SERVICE_API_KEY}\"|" k8s/02-secret.yaml
kubectl apply -f k8s/02-secret.yaml
# Alterar um Secret nao reinicia os pods que ja o leram como variavel de ambiente.
kubectl -n togglemaster rollout restart deploy/evaluation-service
kubectl -n togglemaster rollout status deploy/evaluation-service --timeout=180s
ok "evaluation-service com a chave real"

info "Smoke test pelo Ingress"
BASE_URL="http://$INGRESS_HOST" MASTER_KEY="$MASTER_KEY" \
    SERVICE_API_KEY="$SERVICE_API_KEY" bash scripts/cluster-smoke-test.sh
ok "smoke test 5/5"

# ----------------------------------------------------------------- resumo
info "PRONTO - variaveis para a gravacao"
cat <<RESUMO

  export INGRESS_HOST='${INGRESS_HOST}'
  export API_KEY='${SERVICE_API_KEY}'
  export MASTER_KEY='${MASTER_KEY}'
  export QUEUE_URL='${SQS_URL}'
  echo "http://${INGRESS_HOST}"

Cheque o estado antes de ligar a gravacao:

  kubectl -n togglemaster get pods,svc,ingress,hpa
  kubectl top nodes

ATENCAO: os manifestos em k8s/ agora contem senha e endpoints reais desta
sessao. NAO comite. Para restaurar os placeholders depois da gravacao:

  git checkout k8s/

Se o Auto Scaling trocar algum no durante a sessao, o hop limit do IMDS volta
para 1 e os pods perdem a credencial. Nesse caso:

  bash scripts/provision-aws.sh imds

RESUMO
