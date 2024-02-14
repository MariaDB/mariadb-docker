#!/bin/bash
echo "Extract file"
oldFile="/etc/dump/mysql-dump.sql"
if [ -f "$oldFile" ]; then
    echo "Old file ${oldFile} exists. Remove it ... "
    rm "$oldFile"
    echo "Extracting ..."
fi
sh -c "zstd -d /etc/dump/mysql-dump-data.sql.zst -o /etc/dump/mysql-dump.sql"
echo "Show data in MariaDB"
mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" -e "create database testdb;"
mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "${MARIADB_DB}" < /etc/dump/mysql-dump.sql
mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" -e "show databases; select * from testdb.countries;"