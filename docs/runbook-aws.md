# Runbook — etapas 2 e 3 (infra AWS e add-ons do cluster)

Sequência completa do provisionamento manual na AWS e da instalação do
Metrics Server e do Nginx Ingress Controller.

**Contexto:** AWS Academy Learner Lab. Nesse ambiente não é possível criar IAM
Roles, então tudo usa a role pré-existente **LabRole** e não há IRSA nem KEDA.
Os pods obtêm credenciais da AWS pela role de instância dos nós, via IMDS, que
é o comportamento padrão do SDK — por isso nenhuma credencial da AWS aparece
nos manifestos.

> O lab expira (normalmente 4 h) e **destrói** os recursos. Faça o
> provisionamento, a demonstração e a gravação do vídeo na mesma sessão. Os
> manifestos das etapas 4 e 5 já estão prontos no repo justamente para não
> consumir tempo de lab escrevendo YAML.

---

## 0. Pré-requisitos locais

```bash
aws --version        # AWS CLI v2
kubectl version --client
docker version
```

No painel do lab, **AWS Details → AWS CLI → Show**, copie o bloco para
`~/.aws/credentials` (ele inclui `aws_session_token`). Depois:

```bash
export AWS_REGION=us-east-1
export AWS_PAGER=""                      # evita o pager interativo da CLI
aws sts get-caller-identity              # confirma que a sessão está válida
```

Variáveis usadas no runbook inteiro:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
export CLUSTER_NAME=togglemaster
export PG_PASSWORD='TroqueEstaSenha123'  # a mesma que vai no k8s/02-secret.yaml
```

---

## 1. Rede (VPC default do lab)

O lab já vem com uma VPC default e uma subnet por AZ. O EKS exige subnets em
pelo menos 2 AZs e **não suporta `us-east-1e`** — daí o filtro abaixo.

```bash
export VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)

export VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' --output text)

# Subnets de us-east-1a/b/c/d (exclui 1e, nao suportada pelo EKS)
export SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" \
            Name=availability-zone,Values=us-east-1a,us-east-1b,us-east-1c,us-east-1d \
  --query 'Subnets[].SubnetId' --output text)

export SUBNET_CSV=$(echo "$SUBNET_IDS" | tr ' ' ',')
echo "VPC=$VPC_ID CIDR=$VPC_CIDR"
echo "SUBNETS=$SUBNET_CSV"
```

---

## 2. ECR — 5 repositórios + build e push das imagens

```bash
IMAGE_TAG=v1 bash scripts/ecr-build-push.sh
```

O script cria `togglemaster/<serviço>` para os 5 serviços (idempotente),
compila com `--platform linux/amd64` e publica. No fim ele imprime o
registry completo, que você usa na linha `image:` dos 5 manifestos.

Conferir:

```bash
aws ecr describe-repositories --query 'repositories[].repositoryName' --output table
```

---

## 3. EKS — cluster e node group

O cluster leva ~10 min e o node group outros ~5. **Dispare este passo primeiro
e provisione RDS/ElastiCache em paralelo, em outro terminal** — é o que faz o
provisionamento inteiro caber em ~25 min em vez de 50.

```bash
aws eks create-cluster \
  --name "$CLUSTER_NAME" \
  --role-arn "$LAB_ROLE_ARN" \
  --resources-vpc-config subnetIds="$SUBNET_CSV",endpointPublicAccess=true

aws eks wait cluster-active --name "$CLUSTER_NAME"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes          # ainda vazio: o node group vem agora
```

**Sem `--kubernetes-version` de proposito:** o EKS usa a versao default, que e a
mais recente em suporte padrao. Fixar uma versao aqui envelhece o runbook — uma
versao antiga cai em suporte estendido (mais caro) ou deixa de ser aceita para
clusters novos. Deixando a default, a versao do cluster tambem fica perto da do
seu `kubectl` (veja com `kubectl version --client`), o que evita problemas de
compatibilidade entre cliente e servidor.

Para ver as versoes disponiveis antes, se quiser conferir:

```bash
aws eks describe-cluster-versions --query 'clusterVersions[].clusterVersion' --output table
```

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name ng-togglemaster \
  --node-role "$LAB_ROLE_ARN" \
  --subnets $SUBNET_IDS \
  --instance-types t3.medium \
  --disk-size 20 \
  --scaling-config minSize=2,maxSize=4,desiredSize=2

aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name ng-togglemaster
kubectl get nodes -o wide
```

**Dimensionamento:** 2 × t3.medium = 4 vCPU / 8 GiB. A soma dos `requests` da
aplicação é 750m; no pior caso da demonstração do HPA (10 réplicas do
`evaluation-service` + 8 do `analytics-service` + 3 pods de carga) chega a
~2,5 vCPU. Cabe nos 2 nós, já contando os add-ons.

### Checar o IMDS (importante nesta arquitetura)

Os pods pegam credencial da AWS pela role dos nós, e isso só funciona se o
*hop limit* do IMDS for ≥ 2:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:eks:nodegroup-name,Values=ng-togglemaster" \
  --query 'Reservations[].Instances[].MetadataOptions.HttpPutResponseHopLimit'
```

**Na execucao de 2026-10-16 veio `1`** — ou seja, esperar `2` era otimismo meu:
o node group do EKS criado por CLI nasce com hop limit 1, e os pods **nao**
alcancam o IMDS. Sem credencial, o `evaluation-service` nao publica no SQS e o
`analytics-service` nao le a fila nem grava no DynamoDB.

A correcao, que a role `voclabs` permite, e elevar o hop limit nas instancias
ja em execucao:

```bash
IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:nodegroup-name,Values=ng-togglemaster" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

for id in $IDS; do
  aws ec2 modify-instance-metadata-options --instance-id "$id" \
    --http-put-response-hop-limit 2 --http-endpoint enabled
done
```

Depois **reinicie os dois servicos que usam AWS**: o SDK guarda em cache a falha
de credencial, e um pod que subiu antes da correcao nao se recupera sozinho.

```bash
kubectl -n togglemaster rollout restart deploy/analytics-service deploy/evaluation-service
```

Confirme com `kubectl -n togglemaster logs -l app=analytics-service`, que deve
mostrar `Found credentials from IAM Role: LabRole`.

**Esta correção não é um passo que se faz uma vez.** O
`modify-instance-metadata-options` age **por instância**, não no *launch
template* do node group: toda instância nova nasce de novo com hop limit 1.
Isso acontece sempre que o Auto Scaling substitui um nó — e ele substitui
quando a sessão do lab fecha e as EC2 são paradas. Ou seja, **no início de
cada sessão o hop limit volta a 1**, mesmo que você já o tenha corrigido na
sessão anterior.

Trate como checagem de rotina: rode o `describe-instances` acima no começo de
toda sessão, e o laço de correção se vier `1`. O
`bash scripts/provision-aws.sh imds` faz as duas coisas num comando.

Para testar o IMDS de dentro do cluster antes de aplicar a aplicacao:

```bash
kubectl run imds-test --rm --attach --restart=Never --image=curlimages/curl:8.9.1 \
  --command -- sh -c 'curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" | head -c 20'
```

---

## 4. RDS — 3 instâncias PostgreSQL

Um Security Group liberando 5432 apenas de dentro da VPC:

```bash
export RDS_SG=$(aws ec2 create-security-group \
  --group-name togglemaster-rds \
  --description "PostgreSQL do ToggleMaster, acesso interno a VPC" \
  --vpc-id "$VPC_ID" --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" --protocol tcp --port 5432 --cidr "$VPC_CIDR"
```

Uma instância por serviço, com o banco já criado por `--db-name`. Sem
`--engine-version`, pelo mesmo motivo do EKS: o RDS usa a versao default atual
e o runbook nao envelhece. Na execucao de 2026-10-16 isso deu **PostgreSQL
18.3**, mais novo que o `postgres:16-alpine` do compose — os drivers (`pgx/v4`
no Go, `psycopg2` no Python) e o SQL dos `init.sql` funcionaram sem nenhum
ajuste.

```bash
for db in auth flags targeting; do
  aws rds create-db-instance \
    --db-instance-identifier "togglemaster-${db}" \
    --db-name "${db}_db" \
    --engine postgres \
    --db-instance-class db.t3.micro --allocated-storage 20 \
    --master-username togglemaster --master-user-password "$PG_PASSWORD" \
    --vpc-security-group-ids "$RDS_SG" \
    --no-publicly-accessible --no-multi-az --backup-retention-period 0
done

for db in auth flags targeting; do
  aws rds wait db-instance-available --db-instance-identifier "togglemaster-${db}"
done
```

Endpoints para o `k8s/02-secret.yaml`:

```bash
aws rds describe-db-instances \
  --query 'DBInstances[].[DBInstanceIdentifier,Endpoint.Address]' \
  --output table
```

O schema é aplicado depois, de dentro do cluster, pelo Job
`k8s/90-db-init-job.yaml` — o RDS não é público, e assim não é preciso bastion.

---

## 5. ElastiCache — Redis

```bash
export REDIS_SG=$(aws ec2 create-security-group \
  --group-name togglemaster-redis \
  --description "Redis do ToggleMaster, acesso interno a VPC" \
  --vpc-id "$VPC_ID" --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$REDIS_SG" --protocol tcp --port 6379 --cidr "$VPC_CIDR"

aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name togglemaster \
  --cache-subnet-group-description "Subnets do ToggleMaster" \
  --subnet-ids $SUBNET_IDS

aws elasticache create-cache-cluster \
  --cache-cluster-id togglemaster-redis \
  --engine redis --cache-node-type cache.t3.micro --num-cache-nodes 1 \
  --cache-subnet-group-name togglemaster \
  --security-group-ids "$REDIS_SG"

aws elasticache wait cache-cluster-available --cache-cluster-id togglemaster-redis
```

Endpoint para o `k8s/01-configmap.yaml`:

```bash
aws elasticache describe-cache-clusters \
  --cache-cluster-id togglemaster-redis --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' --output text
```

---

## 6. DynamoDB — tabela de eventos

Mesmo schema do DynamoDB Local do compose (`infra/dynamodb/create-table.sh`):
chave de partição `event_id` (string), on-demand.

```bash
aws dynamodb create-table \
  --table-name ToggleMasterAnalytics \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

aws dynamodb wait table-exists --table-name ToggleMasterAnalytics
```

---

## 7. SQS — fila Standard

```bash
aws sqs create-queue \
  --queue-name togglemaster-events \
  --attributes VisibilityTimeout=60,ReceiveMessageWaitTimeSeconds=20

aws sqs get-queue-url --queue-name togglemaster-events --output text
```

`ReceiveMessageWaitTimeSeconds=20` casa com o long polling do
`analytics-service`; `VisibilityTimeout=60` dá folga para o lote de 10
mensagens ser gravado no DynamoDB antes de voltar para a fila.

---

## 8. Etapa 3 — Metrics Server e Nginx Ingress Controller

### Metrics Server

Sem ele o HPA fica com `<unknown>` em `TARGETS` e nunca escala.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
kubectl -n kube-system rollout status deploy/metrics-server

kubectl top nodes        # tem de retornar CPU/memoria
```

### Nginx Ingress Controller

O manifesto do provider `aws` cria um Service `LoadBalancer` que provisiona um
NLB (leva ~3 min para o DNS responder).

As versoes do Metrics Server e do Nginx ficam fixadas de proposito: `latest`
poderia trazer uma mudanca de comportamento no meio da gravacao. Confira se
ainda sao as atuais em <https://kubernetes.github.io/ingress-nginx/deploy/> e
<https://github.com/kubernetes-sigs/metrics-server/releases>.

A documentacao do ingress-nginx observa que a AWS recomenda o *AWS Load Balancer
Controller* em vez deste manifesto, que usa o provisionamento legado de NLB.
Aqui ele e a escolha certa mesmo assim: o Load Balancer Controller precisa de
IRSA, que exige criar uma IAM Role — impossivel no AWS Academy.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/aws/deploy.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller

export INGRESS_HOST=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$INGRESS_HOST"
```

Conferir que a IngressClass existe — é o `ingressClassName: nginx` do
manifesto da etapa 4:

```bash
kubectl get ingressclass
```

---

## 9. Etapa 4 — aplicar os manifestos

Edite os manifestos com os valores coletados acima. Para ver o que falta:

```bash
grep -rn TROQUE k8s/
```

- `01-configmap.yaml` — URL da fila SQS e endpoint do ElastiCache
- `02-secret.yaml` — senha e os 3 endpoints do RDS, e a `MASTER_KEY`
- `10-` a `14-` — o ID da conta AWS na linha `image:`

Na primeira passada deixe o `SERVICE_API_KEY` como está: a chave de verdade só
pode ser emitida depois que o `auth-service` estiver no ar.

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/
```

**Se o apply do Ingress falhar** com erro de webhook (`failed calling webhook
... no endpoints available`), e porque o Nginx instalou um *admission webhook*
que valida objetos Ingress e os pods dele ainda nao estao prontos. Espere o
controller e aplique so o Ingress:

```bash
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
kubectl apply -f k8s/20-ingress.yaml
```

### Schema dos bancos

```bash
kubectl -n togglemaster create configmap togglemaster-db-schemas \
  --from-file=auth.sql=auth-service/db/init.sql \
  --from-file=flags.sql=flag-service/db/init.sql \
  --from-file=targeting.sql=targeting-service/db/init.sql

kubectl apply -f k8s/90-db-init-job.yaml
kubectl -n togglemaster wait --for=condition=complete job/db-init --timeout=120s
kubectl -n togglemaster logs job/db-init
```

```bash
kubectl -n togglemaster get pods,svc,ingress,hpa
```

Os pods ficam `Ready` tão logo o RDS responda — o `/ready` faz só um
`SELECT 1` e não depende da tabela. O que depende do Job é o **uso** da API:
antes dele, `/flags` e `/rules` respondem 500 por tabela inexistente. Por isso
o Job vem antes do smoke test.

### Chave de API de serviço

**A ordem aqui importa, e a versão anterior deste runbook a tinha invertida.**
Ela mandava rodar o smoke test primeiro e só depois gravar a `SERVICE_API_KEY`
no Secret. **Isso nunca fecha 5/5 numa infra recém-criada:** o passo 4/5 chama
`/evaluate`, e o `evaluation-service` usa a `SERVICE_API_KEY` do próprio
ambiente para falar com o `flag-service`. Com o placeholder ele toma `401`, o
Ingress devolve `502`, e o script aborta — foi exatamente o que aconteceu na
execução de 2026-11-02.

A ordem correta é emitir a chave **antes** do smoke test. Primeiro emita:

```bash
KEY_RESP=$(curl -fsS -X POST "http://${INGRESS_HOST}/admin/keys" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <a MASTER_KEY do 02-secret.yaml>" \
  -d '{"name":"service-key-eks"}')

SERVICE_API_KEY=$(printf '%s' "$KEY_RESP" \
  | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
```

Grave no `SERVICE_API_KEY` do `k8s/02-secret.yaml`, aplique, e reinicie:

```bash
kubectl apply -f k8s/02-secret.yaml
kubectl -n togglemaster rollout restart deploy/evaluation-service
kubectl -n togglemaster rollout status deploy/evaluation-service
```

O `rollout restart` é necessário porque alterar um Secret não reinicia os pods
que já o leram como variável de ambiente.

**Só então** rode o smoke test, passando a chave no ambiente para que ele reuse
a existente em vez de emitir outra:

```bash
BASE_URL="http://$INGRESS_HOST" MASTER_KEY='<a MASTER_KEY do 02-secret.yaml>' \
  SERVICE_API_KEY="$SERVICE_API_KEY" bash scripts/cluster-smoke-test.sh
```

O passo 2/5 deve dizer *"usando a SERVICE_API_KEY do ambiente"*. O script cria
a flag e a regra, avalia 20 usuários e confere os eventos no DynamoDB — 5/5.

O `scripts/provision-aws.sh` já faz tudo isso na ordem certa, sem edição
manual de manifesto.

---

## 10. Etapa 5 — demonstrar o HPA

Em dois terminais:

```bash
# terminal 1 - observar
kubectl -n togglemaster get hpa -w
```

```bash
# terminal 2 - ligar a carga
kubectl -n togglemaster scale deploy/loadgen --replicas=3
```

O `evaluation-service` escala por CPU direta do `/evaluate`; o
`analytics-service` escala em cascata, porque cada avaliação publica um evento
no SQS e o backlog mantém o worker ocupado.

```bash
kubectl -n togglemaster get pods -l app=evaluation-service
kubectl -n togglemaster top pods

QUEUE_URL=$(aws sqs get-queue-url --queue-name togglemaster-events --output text)
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages

aws dynamodb scan --table-name ToggleMasterAnalytics --select COUNT --query Count
```

### Envio manual de mensagens para o SQS

Entregável do vídeo listado **separadamente** da carga no `/evaluate`: aqui as
mensagens vão direto para a fila pela AWS CLI, sem passar pela aplicação, e o
`analytics-service` escala só por causa do backlog que elas criam.

```bash
bash scripts/sqs-send-manual.sh            # 90 s, 6 remetentes em paralelo
```

O corpo precisa ter exatamente as 4 chaves que o `analytics-service` lê em
`process_message` (`user_id`, `flag_name`, `result`, `timestamp`), e `result`
tem de ser booleano JSON — faltando uma chave, o `put_item` nunca acontece, a
mensagem não é apagada da fila e vira uma *poison pill* girando para sempre.

O script usa `flag_name: manual-sqs-demo` de propósito, para que esses eventos
fiquem distinguíveis dos que vieram do `/evaluate`:

```bash
aws dynamodb scan --table-name ToggleMasterAnalytics --select COUNT \
  --filter-expression 'flag_name = :f' \
  --expression-attribute-values '{":f":{"S":"manual-sqs-demo"}}' \
  --query Count
```

Desligar a carga e mostrar o scale in (janela de estabilização de 120 s):

```bash
kubectl -n togglemaster scale deploy/loadgen --replicas=0
```

---

## Troubleshooting

**HPA com `<unknown>` em TARGETS** — o Metrics Server não está servindo
métricas. Veja `kubectl -n kube-system logs deploy/metrics-server`. Se o erro
for de certificado do kubelet:

```bash
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

**Erro `Unable to locate credentials` nos logs** — o IMDS não está alcançável.
A correção de primeira linha é elevar o hop limit, na seção *Checar o IMDS* do
passo 3. Use o Secret abaixo **apenas** se a conta não permitir
`ec2:ModifyInstanceMetadataOptions`, porque estas credenciais **expiram junto
com a sessão** do lab:

Observação: o pod não entra em `CrashLoopBackOff` por isso. Ele fica `Running`
mas `0/1`, com o `/ready` em 503 — é o readiness tirando o pod do Service sem
reiniciá-lo, que é o comportamento desejado.

```bash
kubectl -n togglemaster create secret generic aws-lab-creds \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN"

for d in evaluation-service analytics-service; do
  kubectl -n togglemaster set env deploy/$d --from=secret/aws-lab-creds
done
```

**Cluster com 0 nós, tudo `Pending`, mas as EC2 aparecem `running`** — o
bootstrap do nó falhou por um *explicit deny* de SCP, e esse deny é
**transitório, amarrado à virada de sessão do lab**. Quando a sessão fecha, as
EC2 são paradas, o Auto Scaling as substitui, e as instâncias que nascem nessa
janela tomam `403 UnauthorizedOperation` em `ec2:DescribeInstances`. O
`nodeadm` do AL2023 precisa dessa chamada para se registrar, tenta 8 vezes e
desiste — o nó nunca entra no cluster. Confirme no console serial:

```bash
aws ec2 get-console-output --instance-id <id> --output text | grep -i "nodeadm\|Unauthorized"
```

Não há permissão a ajustar: a SCP vive na organização da AWS Academy e a role
`voclabs` não a alcança. **A correção é terminar as instâncias travadas e
deixar o Auto Scaling subir substitutas** — dentro de uma sessão já ativa o
bootstrap funciona normalmente. Na execução de 2026-11-01 as substitutas
entraram em ~76 s.

```bash
aws ec2 terminate-instances --instance-ids <id-1> <id-2>
aws eks wait nodegroup-active --cluster-name togglemaster --nodegroup-name ng-togglemaster
kubectl get nodes
```

Lembre que os nós novos nascem com hop limit 1: rode
`bash scripts/provision-aws.sh imds` depois.

**Pods `Pending` com `Insufficient cpu`** — o HPA pediu mais do que os 2 nós
suportam:

```bash
aws eks update-nodegroup-config --cluster-name togglemaster \
  --nodegroup-name ng-togglemaster \
  --scaling-config minSize=2,maxSize=4,desiredSize=3
```

**`ImagePullBackOff`** — o ID da conta na linha `image:` está errado ou a
role dos nós não tem permissão de pull. Veja
`kubectl -n togglemaster describe pod <pod>`.

**Ingress sem endereço** — o NLB leva alguns minutos. Se passar de ~5 min, veja
`kubectl -n ingress-nginx describe svc ingress-nginx-controller`.

---

## Limpeza (se a sessão não for expirar sozinha)

Apague o Ingress **antes** do cluster: o NLB é criado pelo controller do
Kubernetes e, se o cluster for removido primeiro, o load balancer fica órfão.

```bash
kubectl delete -f k8s/ --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/aws/deploy.yaml

aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name ng-togglemaster
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name ng-togglemaster
aws eks delete-cluster --name "$CLUSTER_NAME"

for db in auth flags targeting; do
  aws rds delete-db-instance --db-instance-identifier "togglemaster-${db}" \
    --skip-final-snapshot --delete-automated-backups
done
aws elasticache delete-cache-cluster --cache-cluster-id togglemaster-redis
aws dynamodb delete-table --table-name ToggleMasterAnalytics
aws sqs delete-queue --queue-url "$(aws sqs get-queue-url --queue-name togglemaster-events --output text)"
```
