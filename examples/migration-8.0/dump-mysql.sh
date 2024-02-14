#!/bin/bash

echo 'MariaDB service started.'
# Run your commands and exit container
whoami # mysql
# sh -c "chown -R mysql:mysql /etc/dump" # Operation permitted
echo 'Dump and compress MySQL data with changed collation ...'
fileName="mysql-dump-data.sql.zst"
if [ -f "$fileName" ]; then
    echo "File ${fileName} exists. Remove it ... "
    rm "$fileName"
fi
sh -c "mariadb-dump -h${MYSQL_CONT_NAME} -uroot -p${MARIADB_ROOT_PASSWORD} ${MARIADB_DB} | sed 's/utf8mb4_0900/uca1400/g' | zstd > /etc/dump/${fileName}"