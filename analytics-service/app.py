import os
import sys
import threading
import json
import uuid
import time
import logging
import boto3
from botocore.exceptions import NoCredentialsError, ClientError
from flask import Flask, jsonify
from dotenv import load_dotenv

# Configura o logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
log = logging.getLogger(__name__)

# Carrega .env para desenvolvimento local
load_dotenv()

# --- Configuração ---
AWS_REGION = os.getenv("AWS_REGION")
SQS_QUEUE_URL = os.getenv("AWS_SQS_URL")
DYNAMODB_TABLE_NAME = os.getenv("AWS_DYNAMODB_TABLE")

if not all([AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE_NAME]):
    log.critical("Erro: AWS_REGION, AWS_SQS_URL, e AWS_DYNAMODB_TABLE devem ser definidos.")
    sys.exit(1)

# --- Clientes Boto3 ---
# Criamos a sessão uma vez
# Endpoints customizados permitem apontar para o SQS/DynamoDB locais do
# docker-compose (ElasticMQ e DynamoDB Local). Em produção ficam vazios e o
# boto3 usa os endpoints padrão da AWS.
SQS_ENDPOINT_URL = os.getenv("AWS_SQS_ENDPOINT") or None
DYNAMODB_ENDPOINT_URL = os.getenv("AWS_DYNAMODB_ENDPOINT") or None

try:
    session = boto3.Session(region_name=AWS_REGION)
    sqs_client = session.client("sqs", endpoint_url=SQS_ENDPOINT_URL)
    dynamodb_client = session.client("dynamodb", endpoint_url=DYNAMODB_ENDPOINT_URL)
    log.info(f"Clientes Boto3 inicializados na região {AWS_REGION}")
    if SQS_ENDPOINT_URL or DYNAMODB_ENDPOINT_URL:
        log.info(f"Endpoints locais -> SQS: {SQS_ENDPOINT_URL}, DynamoDB: {DYNAMODB_ENDPOINT_URL}")
except NoCredentialsError:
    log.critical("Credenciais da AWS não encontradas. Verifique seu ambiente.")
    sys.exit(1)
except Exception as e:
    log.critical(f"Erro ao inicializar o Boto3: {e}")
    sys.exit(1)


# --- SQS Worker ---

def process_message(message):
    """ Processa uma única mensagem SQS e a insere no DynamoDB """
    try:
        log.info(f"Processando mensagem ID: {message['MessageId']}")
        body = json.loads(message['Body'])
        
        # Gera um ID único para o item no DynamoDB
        event_id = str(uuid.uuid4())
        
        # Constrói o item no formato do DynamoDB
        item = {
            'event_id': {'S': event_id},
            'user_id': {'S': body['user_id']},
            'flag_name': {'S': body['flag_name']},
            'result': {'BOOL': body['result']},
            'timestamp': {'S': body['timestamp']}
        }
        
        # Insere no DynamoDB
        dynamodb_client.put_item(
            TableName=DYNAMODB_TABLE_NAME,
            Item=item
        )
        
        log.info(f"Evento {event_id} (Flag: {body['flag_name']}) salvo no DynamoDB.")
        
        # Se tudo deu certo, deleta a mensagem da fila
        sqs_client.delete_message(
            QueueUrl=SQS_QUEUE_URL,
            ReceiptHandle=message['ReceiptHandle']
        )
        
    except json.JSONDecodeError:
        log.error(f"Erro ao decodificar JSON da mensagem ID: {message['MessageId']}")
        # Não deleta a mensagem, pode ser uma "poison pill"
    except ClientError as e:
        log.error(f"Erro do Boto3 (DynamoDB ou SQS) ao processar {message['MessageId']}: {e}")
        # Não deleta a mensagem, tenta novamente
    except Exception as e:
        log.error(f"Erro inesperado ao processar {message['MessageId']}: {e}")
        # Não deleta a mensagem, tenta novamente

# --- Estado de saude do worker ---
# O worker roda em thread de background, entao o Flask responderia 200 mesmo
# com a thread morta. Estas variaveis expoem o estado real para as probes.
_worker_thread = None
_worker_state_lock = threading.Lock()
_last_successful_poll = None

# O long-polling espera ate 20s por mensagens, logo um poll bem-sucedido deve
# ocorrer a cada ~20s. 90s da folga para os retries de 10s do loop.
POLL_STALE_AFTER_SECONDS = 90


def _mark_poll_ok():
    global _last_successful_poll
    with _worker_state_lock:
        _last_successful_poll = time.monotonic()


def _seconds_since_last_poll():
    with _worker_state_lock:
        if _last_successful_poll is None:
            return None
        return time.monotonic() - _last_successful_poll


def sqs_worker_loop():
    """ Loop principal do worker que ouve a fila SQS """
    log.info("Iniciando o worker SQS...")
    while True:
        try:
            # Long-polling: espera até 20s por mensagens
            response = sqs_client.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,  # Processa em lotes de até 10
                WaitTimeSeconds=20
            )
            _mark_poll_ok()
            
            messages = response.get('Messages', [])
            if not messages:
                # Nenhuma mensagem, continua o loop
                continue
                
            log.info(f"Recebidas {len(messages)} mensagens.")
            
            for message in messages:
                process_message(message)
                
        except ClientError as e:
            log.error(f"Erro do Boto3 no loop principal do SQS: {e}")
            time.sleep(10) # Pausa antes de tentar novamente
        except Exception as e:
            log.error(f"Erro inesperado no loop principal do SQS: {e}")
            time.sleep(10)

# --- Servidor Flask (Apenas para Health Check) ---

app = Flask(__name__)

@app.route('/health')
def health():
    # Liveness: a thread do worker esta viva? Este servico nao expoe rota de
    # negocio, so o worker -- se a thread morreu, o processo e inutil mesmo
    # respondendo HTTP, e reiniciar o container e exatamente o que resolve.
    # Nao checa SQS/DynamoDB de proposito: dependencia externa fora do ar nao
    # se resolve com restart e derrubaria todas as replicas de uma vez.
    if _worker_thread is None or not _worker_thread.is_alive():
        log.error("Liveness falhou: a thread do worker SQS nao esta viva")
        return jsonify({"status": "unhealthy", "reason": "worker sqs morto"}), 503
    return jsonify({"status": "ok"})


@app.route('/ready')
def ready():
    # Readiness: worker vivo E conseguindo falar com o SQS. Falhar aqui nao
    # reinicia o pod, so sinaliza que ele nao esta processando a fila.
    if _worker_thread is None or not _worker_thread.is_alive():
        return jsonify({"status": "not ready", "reason": "worker sqs morto"}), 503

    idle = _seconds_since_last_poll()
    if idle is None:
        return jsonify({"status": "not ready", "reason": "primeiro poll pendente"}), 503
    if idle > POLL_STALE_AFTER_SECONDS:
        log.warning(f"Readiness falhou: sem poll bem-sucedido ha {int(idle)}s")
        return jsonify({
            "status": "not ready",
            "reason": f"sem poll bem-sucedido ha {int(idle)}s",
        }), 503

    return jsonify({"status": "ready", "last_poll_seconds_ago": int(idle)})

# --- Inicialização ---

def start_worker():
    """ Inicia o worker SQS em uma thread separada """
    global _worker_thread
    worker_thread = threading.Thread(target=sqs_worker_loop, daemon=True)
    worker_thread.start()
    _worker_thread = worker_thread

# Inicia o worker SQS em uma thread de background
# Isso garante que ele inicie tanto com 'flask run' quanto com 'gunicorn'
start_worker()

if __name__ == '__main__':
    port = int(os.getenv("PORT", 8005))
    app.run(host='0.0.0.0', port=port, debug=False)