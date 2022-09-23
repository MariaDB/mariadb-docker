#!/bin/sh
PASS="${MARIADB_PASSWORD:-$MYSQL_PASSWORD}"
mysql -u "${MARIADB_USER:-$MYSQL_USER}" -p"${PASS}" \
	-e 'create table t1 (i int unsigned primary key not null)' \
	"${MARIADB_DATABASE:-$MYSQL_DATABASE}"
