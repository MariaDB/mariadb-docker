#!/bin/bash

echo 'MariaDB service started.'
# Run your commands and exit container
whoami # mysql
# sh -c "chown -R mysql:mysql /etc/dump" # Operation permitted
echo 'Remove files if exist'
files=("mysql-dump-data.sql.zst" "mysql-dump-users.sql.zst" "mysql-dump-stats.sql.zst" "mysql-dump-tzs.sql.zst")
for fileName in "${files[@]}"; do
    if [ -f "$fileName" ]; then
        echo "File ${fileName} exists. Remove it ... "
        rm "$fileName"
    fi
done
echo 'Dump and compress MySQL data with changed collation ...'
fileName="mysql-dump-data.sql.zst"
sh -c "mariadb-dump -h${MYSQL_CONT_NAME} -uroot -p${MARIADB_ROOT_PASSWORD} ${MARIADB_DB} | sed 's/utf8mb4_0900/uca1400/g' | zstd > /etc/dump/${fileName}"
echo 'Dump and compress MySQL users ...'
fileName="mysql-dump-users.sql.zst"
sh -c "mariadb-dump -h${MYSQL_CONT_NAME} -uroot -p${MARIADB_ROOT_PASSWORD} --system=users | zstd > /etc/dump/${fileName}"
echo 'Dump and compress MySQL stats ...'
fileName="mysql-dump-stats.sql.zst"
sh -c "mariadb-dump -h${MYSQL_CONT_NAME} -uroot -p${MARIADB_ROOT_PASSWORD} --system=stats | zstd > /etc/dump/${fileName}"
echo 'Dump and compress MySQL timezones ...'
fileName="mysql-dump-tzs.sql.zst"
sh -c "mariadb-dump -h${MYSQL_CONT_NAME} -uroot -p${MARIADB_ROOT_PASSWORD} --system=timezones | zstd > /etc/dump/${fileName}"
echo 'Show MySQL 8.0 create user'
sh -c "mariadb -h${MYSQL_CONT_NAME} -uroot -p${MARIADB_ROOT_PASSWORD} -e 'SELECT @@print_identified_with_as_hex; show create user current_user();'"