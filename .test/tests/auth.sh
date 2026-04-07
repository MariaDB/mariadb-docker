#!/bin/bash
# Tests for basic password and authentication behavior
# Sourced by run.sh — do not execute directly
# shellcheck disable=SC2154

# Shared between test_mysql_random_password_is_complex and test_mysql_random_password_is_different
_last_random_pass=""

test_required_password() {
	echo -e "Test: expect Failure - none of MYSQL_ALLOW_EMPTY_PASSWORD, MYSQL_RANDOM_ROOT_PASSWORD, MYSQL_ROOT_PASSWORD\n"

	cname="mariadb-container-fail-to-start-options-$RANDOM-$RANDOM"
	docker run --name "$cname" --rm "$image" 2>&1 && die "$cname should fail with unspecified option"
	return 0
}

test_mysql_allow_empty_password_is_empty() {
	echo -e "Test: MYSQL_ALLOW_EMPTY_PASSWORD Implementation is empty value so this should fail\n"
	docker run --rm --name "$cname" -e MYSQL_ALLOW_EMPTY_PASSWORD "$image" && die "$cname should fail with empty MYSQL_ALLOW_EMPTY_PASSWORD"
	echo 'expected failure of empty MYSQL_ALLOW_EMPTY_PASSWORD'
	return 0
}

test_mysql_allow_empty_password_is_clean() {
	echo -e "Test: MYSQL_ALLOW_EMPTY_PASSWORD and defaults to clean environment, +default-storage-engine=InnoDB\n"

	runandwait -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "${image}" --default-storage-engine=InnoDB
	mariadbclient -u root -e 'show databases'

	othertables=$(mariadbclient -u root --skip-column-names -Be "select group_concat(SCHEMA_NAME) from information_schema.SCHEMATA where SCHEMA_NAME not in ('mysql', 'information_schema', 'performance_schema', 'sys')")
	[ "${othertables}" != 'NULL' ] && die "unexpected table(s) $othertables"

	otherusers=$(mariadbclient -u root --skip-column-names -Be "select user,host from mysql.global_priv where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'), ('healthcheck', '::1'), ('healthcheck', '127.0.0.1'), ('healthcheck', 'localhost'))")
	[ "$otherusers" != '' ] && die "unexpected users $otherusers"

	echo "Contents of /var/lib/mysql/{mysql,mariadb}_upgrade_info:"
	docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info \
		|| docker exec "$cid" cat /var/lib/mysql/mariadb_upgrade_info \
		|| die "missing {mariadb,mysql_upgrade}_info on install"
	echo

	killoff
}

test_mysql_root_password_is_set() {
	echo -e "Test: MYSQL_ROOT_PASSWORD and mysql@localhost user\n"

	runandwait -e MYSQL_ROOT_PASSWORD=examplepass -e MARIADB_MYSQL_LOCALHOST_USER=1 "${image}"
	mariadbclient -u root -pexamplepass -e 'select current_user()'
	mariadbclient -u root -pwrongpass -e 'select current_user()' || echo 'expected failure'

	docker exec "$cname" sh -c 'set -x -v; . /etc/os-release; [ $VERSION_ID = "10.1" ] && [ $MARIADB_VERSION =  "13.0.1" ] && exit 1' || die "test for https://github.com/MariaDB/buildbot/pull/945"

	otherusers=$(mariadbclient -u root -pexamplepass --skip-column-names -Be "select user,host from mysql.global_priv where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'), ('mysql','localhost'), ('healthcheck', '::1'), ('healthcheck', '127.0.0.1'), ('healthcheck', 'localhost'))")
	[ "$otherusers" != '' ] && die "unexpected users $otherusers"

	createuser=$(docker exec --user mysql -i \
		"$cname" \
		"$mariadb" \
		--silent \
		-e "show create user")
	# shellcheck disable=SC2016
	[ "${createuser//\'/\`}" == 'CREATE USER `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "mysql@localhost wasn't created how I was expected"

	grants="$(docker exec --user mysql -i \
		"$cname" \
		"$mariadb" \
		--silent \
		-e show\ grants)"

	# shellcheck disable=SC2016
	[ "${grants//\'/\`}" == 'GRANT USAGE ON *.* TO `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "mysql@localhost wasn't granted what I was expected"

	createuser=$(docker exec --user mysql -i \
		"$cname" \
		"$mariadb" --defaults-file=/var/lib/mysql/.my-healthcheck.cnf \
		--silent \
		-e "show create user")
	# shellcheck disable=SC2016,SC2076
	[[ "${createuser//\'/\`}" =~ 'CREATE USER `healthcheck`@`localhost` IDENTIFIED' ]] || \
		[[ "${createuser//\'/\`}" =~ 'CREATE USER `healthcheck`@`::1` IDENTIFIED' ]] || \
		[[ "${createuser//\'/\`}" =~ 'CREATE USER `healthcheck`@`127.0.0.1` IDENTIFIED' ]] || die "healthcheck wasn't created how I was expected"

	grants="$(docker exec --user mysql -i \
		"$cname" \
		"$mariadb" --defaults-file=/var/lib/mysql/.my-healthcheck.cnf \
		--silent \
		-e show\ grants)"

	[[ "${grants//\'/\`}" =~ GRANT\ USAGE\ ON\ *.*\ TO\ \`healthcheck\`@\`localhost\` ]] || \
		[[ "${grants//\'/\`}" =~ GRANT\ USAGE\ ON\ *.*\ TO\ \`healthcheck\`@\`::1\` ]] || \
		[[ "${grants//\'/\`}" =~ GRANT\ USAGE\ ON\ *.*\ TO\ \`healthcheck\`@\`127.0.0.1\` ]] || die "healthcheck wasn't granted what I was expected"
	killoff
}

test_mysql_random_password_is_complex() {
	echo -e "Test: MYSQL_RANDOM_ROOT_PASSWORD, needs to satisfy minimum complexity of simple-password-check plugin and old-mode=''\n"

	runandwait -e MYSQL_RANDOM_ROOT_PASSWORD=1 -e MARIADB_MYSQL_LOCALHOST_USER=1 -e MARIADB_MYSQL_LOCALHOST_GRANTS="RELOAD, PROCESS, LOCK TABLES" \
		"${image}" --plugin-load-add=simple_password_check --old-mode=""
	_last_random_pass=$(docker logs "$cid" | grep 'GENERATED ROOT PASSWORD' 2>&1)
	# trim up until password
	_last_random_pass=${_last_random_pass#*GENERATED ROOT PASSWORD: }
	mariadbclient -u root -p"${_last_random_pass}" -e 'select current_user()'

	docker exec --user mysql -i \
		"$cname" \
		"$mariadb" \
		--silent \
		-e "select 'I connect therefore I am'" || die "I'd hoped to work around MDEV-24111"

	grants="$(docker exec --user mysql -i \
		"$cname" \
		"$mariadb" \
		--silent \
		-e show\ grants)"

	# shellcheck disable=SC2016
	[ "${grants//\'/\`}" == 'GRANT RELOAD, PROCESS, LOCK TABLES ON *.* TO `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "I wasn't granted what I was expected"

	killoff
}

test_mysql_random_password_is_different() {
	echo -e "Test: second instance of MYSQL_RANDOM_ROOT_PASSWORD has a different password (and mysql@localhost can be created)\n"

	runandwait -e MYSQL_RANDOM_ROOT_PASSWORD=1 -e MARIADB_MYSQL_LOCALHOST_USER=1 "${image}" --plugin-load-add=simple_password_check
	newpass=$(docker logs "$cid" | grep 'GENERATED ROOT PASSWORD' 2>&1)
	# trim up until password
	newpass=${newpass#*GENERATED ROOT PASSWORD: }
	mariadbclient -u root -p"${newpass}" -e 'select current_user()'
	killoff

	[ "$_last_random_pass" = "$newpass" ] && die "highly improbable - two consecutive passwords are the same"
	return 0
}

test_mysql_root_host_sets_host() {
	echo -e "Test: MYSQL_ROOT_HOST\n"

	runandwait -e MYSQL_ALLOW_EMPTY_PASSWORD=1 -e MYSQL_ROOT_HOST=apple "${image}"
	ru=$(mariadbclient --skip-column-names -B -u root -e 'select user,host from mysql.global_priv where host="apple"')
	[ "${ru}" = '' ] && die 'root@apple not created'
	killoff
}

test_mysql_root_host_localhost() {
	echo -e "Test: MYSQL_ROOT_HOST=localhost\n"

	runandwait -e MARIADB_ROOT_PASSWORD=bob -e MYSQL_ROOT_HOST=localhost "${image}"
	ru=$(mariadbclient --skip-column-names -B -u root -pbob -e 'select user,host from mysql.global_priv where user="root" and host="localhost"')
	[ "${ru}" = '' ] && die 'root@localhost not created'
	killoff
}

test_complex_passwords() {
	echo -e "Test: complex passwords\n"

	runandwait -e MYSQL_USER=bob -e MYSQL_PASSWORD=$'\n $\' \n' -e MYSQL_ROOT_PASSWORD=$'\n\'\\aa-\x09-zz"_%\n' \
		-e MARIADB_REPLICATION_USER="foo" \
		-e MARIADB_REPLICATION_PASSWORD=$'\n\'\\aa-\x09-zz"_%\n' \
		"${image}"
	mariadbclient --skip-column-names -B -u root -p$'\n\'\\aa-\x09-zz"_%\n' -e 'select 1'
	mariadbclient --skip-column-names -B -u foo -p$'\n\'\\aa-\x09-zz"_%\n' -e 'select 1'
	mariadbclient --skip-column-names -B -u bob -p$'\n $\' \n' -e 'select 1'
	killoff
}

test_password_hash() {
	echo -e "Test: create user passwords using password hash\n"

	initdb=$(mktemp -d)
	chmod go+rx "${initdb}"
	cp -a "$dir"/initdb.d/* "${initdb}"
	chmod -R go+rX "${initdb}"
	sed -i -e 's/^PASS=.*/PASS=jane/' "${initdb}"/a_first.sh
	gzip "${initdb}"/*gz*
	xz "${initdb}"/*xz*
	zstd "${initdb}"/*zst*

	runandwait -e MARIADB_ROOT_PASSWORD_HASH='*61584B76F6ECE8FB9A328E7CF198094B2FAC55C7' \
		-e MARIADB_PASSWORD_HASH='*0FD9A3F0F816D076CF239580A68A1147C250EB7B' \
		-e MARIADB_DATABASE=neptune \
		-e MARIADB_USER=henry \
		-v "${initdb}":/docker-entrypoint-initdb.d:Z \
		"${image}"
	mariadbclient -u root -pbob -e 'select current_user()'
	mariadbclient -u root -pbob -e 'select current_user()'
	mariadbclient -u henry -pjane neptune -e 'select current_user()'

	init_sum=$(mariadbclient --skip-column-names -B -u henry -pjane -P 3306 -h 127.0.0.1 --protocol tcp neptune -e "select sum(i) from t1;")
	[ "${init_sum}" = '1833' ] || die 'initialization order error'
	killoff
	rm -rf "${initdb}"
}
