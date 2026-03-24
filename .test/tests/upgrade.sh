#!/bin/bash
# Tests for upgrade and backup/restore flows
# Sourced by run.sh — do not execute directly

test_mariadbupgrade() {
	docker volume rm m57 || echo "m57 already cleaned"
	docker volume create m57
	docker pull docker.io/library/mysql:5.7
	mariadb=mysql runandwait -v m57:/var/lib/mysql:Z -e MYSQL_INITDB_SKIP_TZINFO=1 -e MYSQL_ROOT_PASSWORD=bob docker.io/library/mysql:5.7
	# clean shutdown required
	docker exec "$cid" mysql -u root -pbob -e "set global innodb_fast_shutdown=0;SHUTDOWN"
	while docker exec "$cid" ls -lad /proc/1; do
		sleep 1
	done

	# tls test to ensure that #592 is resolved
	DOCKER_LIBRARY_START_TIMEOUT=$(( ${DOCKER_LIBRARY_START_TIMEOUT:-10} * 7 )) runandwait -e MARIADB_AUTO_UPGRADE=1 -v "${dir}"/tls:/etc/mysql/conf.d/:z -v m57:/var/lib/mysql:Z "${image}"

	version=$(mariadbclient --skip-column-names --loose-skip-ssl-verify-server-cert -B -u root -pbob -e "SELECT VERSION()")

	docker exec "$cid" ls -la /var/lib/mysql/system_mysql_backup_unknown_version.sql.zst || die "hoping for backup file"

	echo "Did the upgrade run?"
	docker logs "$cid" 2>&1 | grep -A 15 'Starting mariadb-upgrade' || die "missing upgrade message"
	echo

	docker exec "$cid" ls -la /var/lib/mysql/

	echo "Final upgrade info reflects current version?"
	if docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info; then
		upgrade_file=mysql_upgrade_info
	elif docker exec "$cid" cat /var/lib/mysql/mariadb_upgrade_info; then
		upgrade_file=mariadb_upgrade_info
	else
		die "missing {mysql,mariadb}_upgrade_info on install"
	fi
	echo

	upgradeversion=$(docker exec "$cid" cat /var/lib/mysql/$upgrade_file)
	# note VERSION() is longer
	[[ $version =~ ^${upgradeversion} ]] || die "upgrade version didn't match"

	echo "fix version to 5.x"
	docker exec "$cid" sed -i -e 's/[0-9]*\(.*\)/5\1/' /var/lib/mysql/$upgrade_file
	docker exec "$cid" cat /var/lib/mysql/$upgrade_file
	killoff

	runandwait -e MARIADB_AUTO_UPGRADE=1 -v m57:/var/lib/mysql:Z "${image}"

	echo "Did the upgrade run?"
	docker logs "$cid" 2>&1 | grep -A 15 'Starting mariadb-upgrade' || die "missing upgrade from prev"
	echo

	echo "data dir"
	docker exec "$cid" ls -la /var/lib/mysql/
	echo

	echo "Is the right backup file there?"
	docker exec "$cid" ls -la /var/lib/mysql/system_mysql_backup_5."${upgradeversion#*.}".sql.zst || die "missing backup"
	echo

	echo "Final upgrade info reflects current version?"
	docker exec "$cid" cat /var/lib/mysql/$upgrade_file || die "missing mysql_upgrade_info on install"
	upgradeversion=$(docker exec "$cid" cat /var/lib/mysql/$upgrade_file)
	[[ $version =~ ^${upgradeversion} ]] || die "upgrade version didn't match current version"
	echo

	echo "Fixing back to 0 minor version"
	docker exec "$cid" sed -i -e 's/[0-9]*-\(MariaDB\)/0-\1/' /var/lib/mysql/$upgrade_file
	upgradeversion=$(docker exec "$cid" cat /var/lib/mysql/$upgrade_file)
	killoff

	runandwait -e MARIADB_AUTO_UPGRADE=1 -v m57:/var/lib/mysql:Z "${image}"
	docker exec "$cid" cat /var/lib/mysql/$upgrade_file
	newupgradeversion=$(docker exec "$cid" cat /var/lib/mysql/$upgrade_file)
	[ "$upgradeversion" = "$newupgradeversion" ] || die "upgrade versions from mysql_upgrade_info should match"
	docker logs "$cid" 2>&1 | grep -C 5 'MariaDB upgrade not required' || die 'should not have upgraded'

	killoff
	docker volume rm m57
}

test_backup_restore() {
	echo -e "Test: Backup/Restore\n"

	tmpvol=v$RANDOM
	docker volume create "$tmpvol"

	runandwait -v $tmpvol:/backup \
		--env MARIADB_ROOT_PASSWORD=soverysecret \
		"$image"

	# docker ubi volume compat
	docker exec \
		--user root \
		"$cname" \
		chmod ugo+rwt /backup

	docker exec \
		"$cname" \
		mariadb-backup --backup --target-dir=/backup/d --user root --password=soverysecret

	docker exec \
		"$cname" \
		mariadb-backup --prepare --target-dir=/backup/d

	# purge this out, in the server we may end up saving it, but the test here
	# is the user password is reset and file recreated on restore.
	docker exec \
		--workdir /backup/d \
		"$cname" \
		rm -f .my-healthcheck.cnf

	docker exec \
		--workdir /backup/d \
		"$cname" \
		tar -Jcf ../backup.tar.xz .

	docker exec \
		"$cname" \
		rm -rf /backup/d

	killoff

	runandwait -v $tmpvol:/docker-entrypoint-initdb.d/:z \
		--env MARIADB_AUTO_UPGRADE=1 \
		"$image"

	mariadbclient -u root -psoverysecret -e 'select current_user() as connected_ok'

	docker exec "$cname" healthcheck.sh --connect --innodb_initialized
	# healthcheck shouldn't return true on insufficient connection information

	# Enforce fallback to tcp in healthcheck.
	docker exec "$cname" sed -i -e 's/\(socket=\)/\1breakpath/' /var/lib/mysql/.my-healthcheck.cnf

	# select @@skip-networking via tcp successful
	docker exec "$cname" healthcheck.sh --connect

	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'alter user healthcheck@`127.0.0.1` ACCOUNT LOCK'
	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'alter user healthcheck@`::1` ACCOUNT LOCK'

	# ERROR 4151 (HY000): Access denied, this account is locked
	docker exec "$cname" healthcheck.sh --connect

	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'alter user healthcheck@`127.0.0.1` WITH MAX_QUERIES_PER_HOUR 1 ACCOUNT UNLOCK'
	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'alter user healthcheck@`::1` WITH MAX_QUERIES_PER_HOUR 1 ACCOUNT UNLOCK'

	# ERROR 1226 (42000) at line 1: User 'healthcheck' has exceeded the 'max_queries_per_hour' resource (current value: 1)'
	docker exec "$cname" healthcheck.sh --connect
	docker exec "$cname" healthcheck.sh --connect

	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'alter user healthcheck@`127.0.0.1` WITH MAX_QUERIES_PER_HOUR 2000 PASSWORD EXPIRE'
	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'alter user healthcheck@`::1` WITH MAX_QUERIES_PER_HOUR 2000 PASSWORD EXPIRE'
	# ERROR 1820 (HY000) at line 1: You must SET PASSWORD before executing this statement
	docker exec "$cname" healthcheck.sh --connect

	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'set password for healthcheck@`127.0.0.1` = PASSWORD("mismatch")'
	# shellcheck disable=SC2016
	mariadbclient -u root -psoverysecret -e 'set password for healthcheck@`::1` = PASSWORD("mismatch")'

	# ERROR 1045 (28000): Access denied
	docker exec "$cname" healthcheck.sh --connect

	# break port
	docker exec "$cname" sed -i -e 's/\(port=\)/\14/' /var/lib/mysql/.my-healthcheck.cnf
	docker exec "$cname" healthcheck.sh --connect || echo "ok, broken port is a connection failure"

	# break config file
	docker exec "$cname" sed -i -e 's/-client]$//' /var/lib/mysql/.my-healthcheck.cnf
	docker exec "$cname" healthcheck.sh --connect || echo "ok, broken config file is a failure"

	killoff

	docker volume rm "$tmpvol"
	tmpvol=
}
