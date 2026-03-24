#!/bin/bash
# Cria o banco do dashboard além do banco principal (POSTGRES_DB).
# Executado automaticamente pelo entrypoint do PostgreSQL no primeiro start.
set -e

EXTRA_DB="${DASHBOARD_DATABASE_NAME:-siscan_dashboard}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE ${EXTRA_DB} OWNER ${POSTGRES_USER}'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${EXTRA_DB}')
    \gexec
EOSQL

echo "Banco '${EXTRA_DB}' verificado/criado com sucesso."
