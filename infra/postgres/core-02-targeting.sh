#!/bin/bash
# Executado uma unica vez, na primeira inicializacao do container postgres-core.
# O desafio pede apenas 2 instancias PostgreSQL locais, entao este container
# hospeda dois bancos: flags_db (criado pelo POSTGRES_DB) e targeting_db.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
	CREATE DATABASE targeting_db;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname targeting_db -f /schemas/targeting.sql

echo "targeting_db criado e inicializado."
