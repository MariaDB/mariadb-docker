# Sourced, intentionally no shebang
# shellcheck disable=SC2148
docker_process_sql <<-EOSQL
CHANGE MASTER TO
   MASTER_HOST='${MASTER_HOST:-mariadbprimary}',
   MASTER_USER='${MASTER_USER:-repluser}',
   MASTER_PASSWORD='${MASTER_PASSWORD:-replsecret}',
   MASTER_CONNECT_RETRY=3,
   MASTER_LOG_FILE='my-mariadb-bin.000001',
   MASTER_LOG_POS=4;
EOSQL
