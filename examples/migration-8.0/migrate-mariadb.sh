#!/bin/bash
echo "Show data in MariaDB"
mariadb -uroot -psecret -e "create database testdb;"
mariadb -uroot -psecret testdb < /etc/dump/mysql-dump-data-utf8mb4_unicode_ci.sql
mariadb -uroot -psecret  -e "show databases; select * from countries;"