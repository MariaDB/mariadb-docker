#!/bin/bash
# Tests for MariaDB-prefixed environment variables
# Sourced by run.sh — do not execute directly

# Shared between test_mariadb_root_password_is_complex and test_mariadb_root_password_is_different
_last_mariadb_random_pass=""

test_prefer_mariadb_names() {
	echo -e "Test: when provided with MYSQL_ and MARIADB_ names, Prefer MariaDB names\n"

	runandwait -e MARIADB_ROOT_PASSWORD=examplepass -e MYSQL_ROOT_PASSWORD=mysqlexamplepass "${image}"
	mariadbclient -u root -pexamplepass -e 'select current_user()'
	mariadbclient -u root -pwrongpass -e 'select current_user()' || echo 'expected failure of wrong password'
	killoff
}

test_mariadb_allow_empty_root_password_empty() {
	echo -e "Test: MARIADB_ALLOW_EMPTY_ROOT_PASSWORD Implementation is empty value so this should fail\n"

	docker run --rm --name "$cname" -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD "$image" || echo 'expected failure MARIADB_ALLOW_EMPTY_ROOT_PASSWORD is empty'
	return 0
}

test_mariadb_allow_empty_root_password_not_empty() {
	echo -e "Test: MARIADB_ALLOW_EMPTY_ROOT_PASSWORD\n"

	# +Defaults to clean environment
	runandwait -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
	mariadbclient -u root -e 'show databases'

	othertables=$(mariadbclient -u root --skip-column-names -Be "select group_concat(SCHEMA_NAME) from information_schema.SCHEMATA where SCHEMA_NAME not in ('mysql', 'information_schema', 'performance_schema', 'sys')")
	[ "${othertables}" != 'NULL' ] && die "unexpected table(s) $othertables"

	otherusers=$(mariadbclient -u root --skip-column-names -Be "select user,host from mysql.global_priv where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'), ('mysql','localhost'), ('healthcheck', '::1'), ('healthcheck', '127.0.0.1'), ('healthcheck', 'localhost'))")
	[ "$otherusers" != '' ] && die "unexpected users $otherusers"
	killoff
}

test_mariadb_root_password_is_set() {
	echo -e "Test: MARIADB_ROOT_PASSWORD\n"

	runandwait -e MARIADB_ROOT_PASSWORD=examplepass "${image}"
	mariadbclient -u root -pexamplepass -e 'select current_user()'
	mariadbclient -u root -pwrongpass -e 'select current_user()' || echo 'expected failure'
	killoff
}

test_mariadb_root_password_is_complex() {
	echo -e "Test: MARIADB_RANDOM_ROOT_PASSWORD, needs to satisfy minimum complexity of simple-password-check plugin\n"

	runandwait -e MARIADB_RANDOM_ROOT_PASSWORD=1 "${image}" --plugin-load-add=simple_password_check
	_last_mariadb_random_pass=$(docker logs "$cid" 2>&1 | grep 'GENERATED ROOT PASSWORD')
	# trim up until password
	_last_mariadb_random_pass=${_last_mariadb_random_pass#*GENERATED ROOT PASSWORD: }
	mariadbclient -u root -p"${_last_mariadb_random_pass}" -e 'select current_user()'
	killoff
}

test_mariadb_root_password_is_different() {
	echo -e "Test: second instance of MARIADB_RANDOM_ROOT_PASSWORD has a different password\n"

	runandwait -e MARIADB_RANDOM_ROOT_PASSWORD=1 "${image}" --plugin-load-add=simple_password_check
	newpass=$(docker logs "$cid" 2>&1 | grep 'GENERATED ROOT PASSWORD')
	# trim up until password
	newpass=${newpass#*GENERATED ROOT PASSWORD: }
	mariadbclient -u root -p"${newpass}" -e 'select current_user()'
	killoff

	[ "$_last_mariadb_random_pass" = "$newpass" ] && die "highly improbable - two consecutive random passwords are the same"
	return 0
}

test_mariadb_root_host_sets_host() {
	echo -e "Test: MARIADB_ROOT_HOST\n"

	runandwait -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_ROOT_HOST=apple "${image}"
	ru=$(mariadbclient --skip-column-names -B -u root -e 'select user,host from mysql.global_priv where host="apple"')
	[ "${ru}" = '' ] && die 'root@apple not created'
	killoff
}

test_mariadb_user_host() {
	echo -e "Test: MARIADB_USER_HOST makes user host configurable at init\n"

	runandwait -e MARIADB_ROOT_PASSWORD=secr3t \
		-e MARIADB_USER=testuser \
		-e MARIADB_PASSWORD=testpass \
		-e MARIADB_DATABASE=testdb \
		-e MARIADB_USER_HOST=192.168.1.0/255.255.255.0 \
		"${image}"

	uh=$(mariadbclient --skip-column-names -B -u root -p"secr3t" -e "select user,host from mysql.global_priv where user='testuser'")
	[ "${uh}" = '' ] && die 'testuser with custom host not created'
	host=$(mariadbclient --skip-column-names -B -u root -p"secr3t" -e "select host from mysql.global_priv where user='testuser'")
	[ "${host}" = '192.168.1.0/255.255.255.0' ] || die "expected host '192.168.1.0/255.255.255.0' but got '${host}'"
	killoff

	echo -e "Test: MARIADB_USER_HOST defaults to '%' when not specified\n"

	runandwait -e MARIADB_ROOT_PASSWORD=secr3t \
		-e MARIADB_USER=testuser \
		-e MARIADB_PASSWORD=testpass \
		-e MARIADB_DATABASE=testdb \
		"${image}"

	host=$(mariadbclient --skip-column-names -B -u root -p"secr3t" -e "select host from mysql.global_priv where user='testuser'")
	[ "${host}" = '%' ] || die "expected default host '%' but got '${host}'"
	killoff
}
