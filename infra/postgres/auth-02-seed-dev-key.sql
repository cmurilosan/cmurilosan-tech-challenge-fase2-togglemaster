-- APENAS PARA O AMBIENTE LOCAL (docker-compose).
-- Pre-cadastra a chave de API usada pelo evaluation-service para falar com o
-- flag-service e o targeting-service, evitando um passo manual no `up`.
--
--   Chave em texto plano : tm_key_local_dev_0000000000000000
--   SHA-256 armazenado   : 73de80ca4bc5b1c70439166df87c9db622664aa939866dbfc6f934fc984c61b3
--
-- Em producao (RDS) esta seed NAO e aplicada: a chave e criada via
-- POST /admin/keys com a MASTER_KEY.
INSERT INTO api_keys (name, key_hash, is_active)
VALUES (
    'evaluation-service-local',
    '73de80ca4bc5b1c70439166df87c9db622664aa939866dbfc6f934fc984c61b3',
    true
)
ON CONFLICT (key_hash) DO NOTHING;
