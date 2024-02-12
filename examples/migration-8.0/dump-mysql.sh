#!/bin/bash

echo 'MariaDB service started. Dump MySQL data ...'
# Run your commands and exit container
whoami # mysql"
# sh -c "chown -R mysql:mysql /etc/dump" # Operation permitted
# sh -c "ls -la /etc/dump"
sh -c "mariadb-dump -h mysql-container -uroot -psecret testdb > /etc/dump/mysql-dump-data.sql"
sh -c "ls -la /etc/dump/"
echo "List before"
sh -c "cp /etc/dump/mysql-dump-data.sql /etc/dump/mysql-dump-data-utf8mb4_unicode_ci.sql"
sh -c "ls -la /etc/dump/"
echo "List after"
sh -c "sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' /etc/dump/mysql-dump-data-utf8mb4_unicode_ci.sql"