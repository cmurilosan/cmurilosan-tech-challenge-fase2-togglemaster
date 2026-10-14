# ToggleMaster — Microsserviços (Tech Challenge Fase 2)

Ecossistema de feature flags da *DevOps Solutions Inc.* quebrado em 5 microsserviços,
containerizado e preparado para rodar em Kubernetes (EKS).

**Participante:** Cássio Murilo dos Santos

---

## Arquitetura

| Serviço              | Stack  | Porta | Dependência de dados          | Papel                                                |
|----------------------|--------|-------|-------------------------------|------------------------------------------------------|
| `auth-service`       | Go     | 8001  | PostgreSQL (`auth_db`)        | Cria e valida chaves de API                          |
| `flag-service`       | Python | 8002  | PostgreSQL (`flags_db`)       | CRUD das definições de flags                         |
| `targeting-service`  | Python | 8003  | PostgreSQL (`targeting_db`)   | Regras de segmentação (JSONB)                        |
| `evaluation-service` | Go     | 8004  | Redis + SQS                   | *Hot path*: decide `true/false` e publica o evento   |
| `analytics-service`  | Python | 8005  | SQS + DynamoDB                | Worker que consome a fila e grava os eventos         |

Fluxo de uma avaliação:

```
cliente ──> evaluation-service ──┬─> Redis (cache, TTL 30s)
                                 ├─> flag-service ──────> PostgreSQL
                                 ├─> targeting-service ─> PostgreSQL
                                 └─> SQS ──> analytics-service ──> DynamoDB
```

`flag-service` e `targeting-service` validam toda requisição contra o `/validate`
do `auth-service`.

---

## Ambiente local (Docker Compose)

### Pré-requisitos

- Docker Engine + Docker Compose v2
- (opcional) AWS CLI, usada pelo script de smoke test para ler o DynamoDB Local

### Subindo

```bash
cp .env.example .env        # opcional: o compose já tem defaults para tudo
docker compose up -d --build
docker compose ps
```

Containers que sobem:

| Container             | Papel                                                        |
|-----------------------|--------------------------------------------------------------|
| `tm-postgres-auth`    | PostgreSQL #1 — `auth_db`                                     |
| `tm-postgres-core`    | PostgreSQL #2 — `flags_db` + `targeting_db`                   |
| `tm-redis`            | Cache do `evaluation-service`                                 |
| `tm-dynamodb`         | DynamoDB Local — tabela `ToggleMasterAnalytics`               |
| `tm-elasticmq`        | Fila compatível com a API do SQS (extra, para o fluxo offline)|
| `tm-dynamodb-init`    | Job efêmero que cria a tabela do DynamoDB e encerra           |
| `tm-auth-service`     | Aplicação                                                     |
| `tm-flag-service`     | Aplicação                                                     |
| `tm-targeting-service`| Aplicação                                                     |
| `tm-evaluation-service`| Aplicação                                                    |
| `tm-analytics-service`| Aplicação                                                     |

> O desafio exige 9 containers (5 apps + 4 bancos). O `elasticmq` e o
> `dynamodb-init` são adicionais: sem uma fila local o `analytics-service` não
> teria o que consumir e o fluxo ponta a ponta não seria demonstrável sem
> credenciais reais da AWS. Para usar o SQS real basta preencher `AWS_SQS_URL`
> com a URL da fila e deixar `AWS_SQS_ENDPOINT` vazio no `.env`.

### Validando

```bash
bash scripts/smoke-test.sh
```

O script espera os 5 serviços ficarem *ready*, valida a autenticação, cria a flag
`enable-new-dashboard` com uma regra de 50%, dispara 20 avaliações e confere
que os eventos chegaram ao DynamoDB.

Verificação manual rápida:

```bash
# 1. Liveness (processo de pe) e readiness (dependencia alcancavel)
curl http://localhost:8001/health
curl http://localhost:8001/ready

# 2. Criar uma chave de API (a chave local já vem pré-cadastrada, veja abaixo)
curl -X POST http://localhost:8001/admin/keys \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer admin-secreto-123" \
  -d '{"name":"minha-chave"}'

# 3. Avaliar uma flag
curl "http://localhost:8004/evaluate?user_id=user-123&flag_name=enable-new-dashboard"

# 4. Ver os eventos no DynamoDB Local
aws dynamodb scan --table-name ToggleMasterAnalytics \
  --endpoint-url http://localhost:8000
```

### Chave de API do ambiente local

O `evaluation-service` precisa de uma chave válida para falar com o `flag-service`
e o `targeting-service`. Para o `docker compose up` funcionar sem passo manual,
o hash SHA-256 de uma chave fixa de desenvolvimento é semeado no `auth_db`
(`infra/postgres/auth-02-seed-dev-key.sql`):

```
tm_key_local_dev_0000000000000000
```

Essa seed vale **apenas para o ambiente local**. Em produção a chave é criada via
`POST /admin/keys` e injetada por Secret do Kubernetes.

### Derrubando

```bash
docker compose down          # mantém os volumes
docker compose down -v       # apaga também os dados
```

---

## Decisões de containerização

- **Multi-stage em todos os 5 Dockerfiles.** Go compila em `golang:1.21-alpine` e
  o binário estático (`CGO_ENABLED=0`) vai para um `alpine:3.20` limpo. Python
  instala as dependências num virtualenv em `python:3.11-slim` e só o `/opt/venv`
  é copiado para a imagem final.
- **Usuário não-root** (`uid 10001`) em todas as imagens.
- **`go mod download` antes de copiar o código**, para que alterações no código
  não invalidem o cache das dependências.
- **`alpine` em vez de `distroless`** no estágio final dos serviços Go: o
  `wget` do BusyBox permite `HEALTHCHECK` no Compose e probes no Kubernetes sem
  embarcar binários extras.
- **Python 3.11** (e não 3.12) porque o `gunicorn` 20.1.0 depende de
  `setuptools`, que deixou de vir pré-instalado nas imagens 3.12+.

## Ajustes necessários no código-fonte original

O código entregue não compilava/subia como estava. As correções foram mínimas e
estão isoladas nos commits iniciais:

| Serviço              | Problema                                                                 | Correção                                                        |
|----------------------|--------------------------------------------------------------------------|-----------------------------------------------------------------|
| `auth-service`       | Imports não usados (`fmt`, `crypto/sha256`, `encoding/hex`) — não compila | Imports removidos                                               |
| `auth-service`       | `pgx/v4/stdlib` importado sem `_`, sendo usado apenas pelo driver         | Trocado por import em branco (`_`)                              |
| `auth-service`       | `go.mod` declarava `pgx/v4/stdlib` como módulo (é um pacote)              | Linha removida do `go.mod`                                      |
| `evaluation-service` | `evaluator.go` usa `os.Getenv` sem importar `os` — não compila           | Import `os` adicionado                                          |
| `flag/targeting/analytics` | `Flask 2.2.2` sem *upper bound* puxa `Werkzeug` 3.x e quebra no boot | `Werkzeug==2.2.3` fixado no `requirements.txt`                  |
| `evaluation/analytics` | Endpoints AWS fixos, impedindo emulação local                           | Suporte opcional a `AWS_SQS_ENDPOINT` / `AWS_DYNAMODB_ENDPOINT` |
| `auth-service`       | `go.sum` ausente — `go build` falha com *missing go.sum entry*            | `go.sum` gerado via `go mod tidy`                               |
| `evaluation-service` | `go.sum` era uma **cópia do `go.mod`**, não um arquivo de somas           | `go.sum` regenerado via `go mod tidy`                           |
| `evaluation-service` | `evaluator.go` importa `context` sem usar (usa o `ctx` global) — não compila | Import removido                                             |

As variáveis de endpoint ficam vazias na AWS real, mantendo o comportamento
original em produção.

---

## Health checks e readiness

Os cinco serviços vinham com um único `/health` estático, que respondia
`{"status": "ok"}` sem verificar nada. Isso serve de *liveness* mas não de
*readiness*: o pod entraria no Service antes de a dependência estar alcançável e
as primeiras requisições falhariam. Foi adicionado um `/ready` em cada serviço:

| Serviço              | `/health` (liveness)              | `/ready` (readiness)                     |
|----------------------|-----------------------------------|------------------------------------------|
| `auth-service`       | processo responde                 | `PingContext` no PostgreSQL              |
| `flag-service`       | processo responde                 | `SELECT 1` no PostgreSQL                 |
| `targeting-service`  | processo responde                 | `SELECT 1` no PostgreSQL                 |
| `evaluation-service` | processo responde                 | `PING` no Redis                          |
| `analytics-service`  | thread do worker SQS está viva    | worker vivo + poll recente no SQS        |

Três decisões de desenho por trás disso:

- **O liveness não toca em dependência externa.** Se o RDS ou o Redis cair,
  reiniciar o container não resolve — e um liveness que checa banco derrubaria
  todas as réplicas ao mesmo tempo, em cascata. Quem reage a dependência
  indisponível é o readiness, tirando o pod do balanceamento sem reiniciá-lo.
- **O readiness do `evaluation-service` checa só o Redis**, não o `flag-service`
  nem o `targeting-service`. Encadear readiness em dependência de serviço
  multiplica indisponibilidades: uma falha neles tiraria este pod do ar junto.
- **O `analytics-service` é a exceção no liveness.** Ele não expõe rota de
  negócio: o trabalho roda em uma thread de background, e o Flask respondia 200
  mesmo com essa thread morta — pod "saudável" sem consumir a fila. Aqui o
  liveness reflete `is_alive()` da thread, que é o único caso em que reiniciar
  o container é a correção certa.

Os `healthcheck` do `docker-compose.yml` apontam para `/ready`, porque
`depends_on: condition: service_healthy` é semanticamente readiness — o
`flag-service` só sobe depois de o `auth-service` conseguir falar com o banco.

---

## Variáveis de ambiente

Todas têm default no `docker-compose.yml`; veja `.env.example` para a lista
completa e os valores de produção.

---

## Status da entrega

- [x] **Etapa 1** — Dockerfiles multi-stage + `docker-compose.yml` com os 5 serviços e os bancos locais
- [ ] **Etapa 2** — Infra na AWS (EKS, ECR, 3x RDS, ElastiCache, DynamoDB, SQS)
- [ ] **Etapa 3** — Metrics Server + Nginx Ingress Controller no cluster
- [ ] **Etapa 4** — Manifestos K8s (Namespace, Deployment, Service, Secret, ConfigMap, Ingress)
- [ ] **Etapa 5** — HPA do `evaluation-service` e do `analytics-service`
- [ ] Vídeo de demonstração + relatório de entrega
