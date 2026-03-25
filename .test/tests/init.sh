#!/bin/bash
# Tests for initialization, timezone, secrets, and configuration
# Sourced by run.sh — do not execute directly
# shellcheck disable=SC2154

test_mysql_initdb_skip_tzinfo_empty() {
	echo -e "Test: MYSQL_INITDB_SKIP_TZINFO='' should still load timezones\n"

	# ONLY_FULL_GROUP_BY - test for MDEV-29347
	runandwait -e MYSQL_INITDB_SKIP_TZINFO= -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "${image}" --default-time-zone=Europe/Berlin --sql-mode=ONLY_FULL_GROUP_BY
	tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
	[ "${tzcount}" = '0' ] && die "should exist timezones"
	[ "$(mariadbclient --skip-column-names -B -u root -e 'SELECT @@time_zone')" != "Europe/Berlin" ] && die "Didn't set timezone to Berlin"
	killoff
}

test_mysql_initdb_skip_tzinfo_no_empty() {
	echo -e "Test: MYSQL_INITDB_SKIP_TZINFO=1 should not load timezones\n"

	runandwait -e MYSQL_INITDB_SKIP_TZINFO=1 -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "${image}"
	tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
	[ "${tzcount}" = '0' ] || die "timezones shouldn't be loaded - found ${tzcount}"
	killoff
}

test_secrets_via_file() {
	echo -e "Test: Secrets _FILE vars should be same as env directly\n"

	secretdir=$(mktemp -d)
	chmod go+rx "${secretdir}"
	echo bob > "$secretdir"/pass
	echo pluto > "$secretdir"/host
	echo titan > "$secretdir"/db
	echo ron > "$secretdir"/u
	echo '*D87991C62A9CAEDC4AE0F608F19173AC7E614952' > "$secretdir"/p

	tmpvol=v$RANDOM
	docker volume create "$tmpvol"
	# any container will work with tar in it, we may well use the image we have
	(cd "$secretdir" || exit ; tar -cf - .) | docker run --rm --volume "$tmpvol":/v --user root -i "${image}" tar -xf - -C /v
	rm -rf "${secretdir}"

	runandwait \
		-v "$tmpvol":/run/secrets \
		-e MYSQL_ROOT_PASSWORD_FILE=/run/secrets/pass \
		-e MYSQL_ROOT_HOST_FILE=/run/secrets/host \
		-e MYSQL_DATABASE_FILE=/run/secrets/db \
		-e MYSQL_USER_FILE=/run/secrets/u \
		-e MARIADB_PASSWORD_HASH_FILE=/run/secrets/p \
		"${image}"

	host=$(mariadbclient --skip-column-names -B -u root -pbob -e 'select host from mysql.global_priv where user="root" and host="pluto"' titan)
	[ "${host}" != 'pluto' ] && die 'root@pluto not created'
	creation=$(mariadbclient --skip-column-names -B -u ron -pscappers -P 3306 --protocol tcp titan -e "CREATE TABLE landing(i INT)")
	[ "${creation}" = '' ] || die 'creation error'
	killoff
	docker volume rm "$tmpvol"
	tmpvol=
}

test_docker_entrypoint_initdb() {
	echo -e "Test: docker-entrypoint-initdb.d Initialization order is correct and processed\n"

	initdb=$(prepare_initdb)

	runandwait \
		-v "${initdb}":/docker-entrypoint-initdb.d:Z \
		-e MYSQL_ROOT_PASSWORD=ssh \
		-e MYSQL_DATABASE=titan \
		-e MYSQL_USER=ron \
		-e MYSQL_PASSWORD=scappers \
		"${image}"

	init_sum=$(mariadbclient --skip-column-names -B -u ron -pscappers -P 3306 -h 127.0.0.1 --protocol tcp titan -e "select sum(i) from t1;")
	[ "${init_sum}" = '1833' ] || die 'initialization order error'
	killoff
	rm -rf "${initdb}"
}

test_mariadb_initdb_skip_tzinfo_empty() {
	echo -e "Test: MARIADB_INITDB_SKIP_TZINFO=''\n"

	runandwait -e MARIADB_INITDB_SKIP_TZINFO= -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
	tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
	[ "${tzcount}" = '0' ] && die "should exist time zones"

	# note uses previous instance
	echo -e "Test: default configuration items are present\n"
	arg_expected=0
	docker exec -i "$cid" my_print_defaults --mysqld |
		{
		while read -r line; do
			case $line in
			--host-cache-size=0|--skip-name-resolve)
				echo "$line" found
				(( arg_expected++ )) || : ;;
			esac
		done
		[ "$arg_expected" -eq 2 ] || die "expected both host-cache-size=0 and skip-name-resolve"
	}
	killoff
}

test_mariadb_initdb_skip_tzinfo_not_empty() {
	echo -e "Test: MARIADB_INITDB_SKIP_TZINFO=1\n"

	runandwait -e MARIADB_INITDB_SKIP_TZINFO=1 -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
	tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
	[ "${tzcount}" = '0' ] || die "timezones shouldn't be loaded - found ${tzcount}"
	killoff
}

test_encryption() {
	echo -e "Test: Startup using encryption\n"

	runandwait -v "${dir}"/encryption_conf/:/etc/mysql/conf.d/:z -v "${dir}"/encryption:/etc/encryption/:z -v "${dir}"/initenc:/docker-entrypoint-initdb.d/:z \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=123-databasename-456 -e MARIADB_USER=123-username-456 -e MARIADB_PASSWORD=hope "${image}"
	mariadbclient -u root -e 'SELECT * FROM information_schema.innodb_tablespaces_encryption' || die 'Failed to start container'

	cnt=$(mariadbclient --skip-column-names -B -u root -e 'SELECT COUNT(*) FROM information_schema.innodb_tablespaces_encryption')
	[ "$cnt" -gt 0 ] || die 'Failed to initialize encryption on initialization'
	killoff
}
