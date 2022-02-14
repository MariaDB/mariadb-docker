#!/bin/bash
set -eo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

if [ $# -eq 0 ]
then
	echo "An image argument is required" >&2
	exit 1
fi

image="$1"

architecture=$(docker image inspect --format '{{.Architecture}}' "$image")

killoff()
{
	[ -n "$cid" ] && docker kill "$cid" > /dev/null
	sleep 2
	if [ -n "$cid" ]; then
	       docker rm -v -f "$cid" > /dev/null || true
	fi
	cid=""
}

die()
{
	[ -n "$cid" ] && docker logs "$cid"
	killoff
        echo "$@" >&2
        exit 1
}
trap "killoff" EXIT

runandwait()
{
	cname="mariadb-container-$RANDOM-$RANDOM"
	cid="$(
		docker run -d \
			--name "$cname" --rm --publish 3306 "$@"
	)"
	port=$(docker port "$cname" 3306)
	port=${port#*:}

	waiting=${DOCKER_LIBRARY_START_TIMEOUT:-10}
	echo "waiting to start..."
	set +e +o pipefail +x
	while [ "$waiting" -gt 0 ]
	do
		(( waiting-- ))
		sleep 1
		if ! docker exec -i "$cid" mysql -h localhost --protocol tcp -P 3306 -e 'select 1' 2>&1 | grep -F "Can't connect" > /dev/null
		then
			break
		fi
        done
	set -eo pipefail -x
	if [ "$waiting" -eq 0 ]
	then
		die 'timeout'
	fi
}

mariadbclient() {
	docker exec -i \
		"$cname" \
		mysql \
		--host 127.0.0.1 \
		--protocol tcp \
		--silent \
		"$@"
}

mariadbclient_unix() {
	docker exec -i \
		"$cname" \
		mysql \
		--silent \
		"$@"
}

case ${2:-all} in
	all|required_password)

echo -e "Test: expect Failure - none of MYSQL_ALLOW_EMPTY_PASSWORD, MYSQL_RANDOM_ROOT_PASSWORD, MYSQL_ROOT_PASSWORD\n"

cname="mariadb-container-fail-to-start-options-$RANDOM-$RANDOM"
docker run --name "$cname" --rm "$image" 2>&1 && die "$cname should fail with unspecified option"

	;&
	mysql_allow_empty_password_is_empty)

echo -e "Test: MYSQL_ALLOW_EMPTY_PASSWORD Implementation is empty value so this should fail\n"
docker run  --rm  --name "$cname" -e MYSQL_ALLOW_EMPTY_PASSWORD  "$image" || echo 'expected failure of empty MYSQL_ALLOW_EMPTY_PASSWORD'

	;&
	mysql_allow_empty_password_is_clean)

echo -e "Test: MYSQL_ALLOW_EMPTY_PASSWORD and defaults to clean environment, +default-storage-engine=InnoDB\n"

runandwait -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "${image}" --default-storage-engine=InnoDB
mariadbclient -u root -e 'show databases'

othertables=$(mariadbclient -u root --skip-column-names -Be "select group_concat(SCHEMA_NAME) from information_schema.SCHEMATA where SCHEMA_NAME not in ('mysql', 'information_schema', 'performance_schema', 'sys')")
[ "${othertables}" != 'NULL' ] && die "unexpected table(s) $othertables"

otherusers=$(mariadbclient -u root --skip-column-names -Be "select user,host from mysql.user where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'))")
[ "$otherusers" != '' ] && die "unexpected users $otherusers"

	echo "Contents of /var/lib/mysql/mysql_upgrade_info:"
	docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info || die "missing mysql_upgrade_info on install"
	echo

killoff

	;&
	mysql_root_password_is_set)

	echo -e "Test: MYSQL_ROOT_PASSWORD and mysql@localhost user\n"

	runandwait -e MYSQL_ROOT_PASSWORD=examplepass -e MARIADB_MYSQL_LOCALHOST_USER=1 "${image}"
	mariadbclient -u root -pexamplepass -e 'select current_user()'
	mariadbclient -u root -pwrongpass -e 'select current_user()' || echo 'expected failure'

	otherusers=$(mariadbclient -u root -pexamplepass --skip-column-names -Be "select user,host from mysql.user where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'), ('mysql','localhost'))")
	[ "$otherusers" != '' ] && die "unexpected users $otherusers"

	createuser=$(docker exec --user mysql -i \
		"$cname" \
		mysql \
		--silent \
		-e "show create user")
	# shellcheck disable=SC2016
	[ "${createuser//\'/\`}" == 'CREATE USER `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "I wasn't created how I was expected"

	grants="$(docker exec --user mysql -i \
		$cname \
		mysql \
		--silent \
		-e show\ grants)"

	# shellcheck disable=SC2016
	[ "${grants//\'/\`}" == 'GRANT USAGE ON *.* TO `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "I wasn't granted what I was expected"

	killoff

	;&
	mysql_random_password_is_complex)

echo -e "Test: MYSQL_RANDOM_ROOT_PASSWORD, needs to satisify minimium complexity of simple-password-check plugin\n"

runandwait -e MYSQL_RANDOM_ROOT_PASSWORD=1 -e MARIADB_MYSQL_LOCALHOST_USER=1 -e MARIADB_MYSQL_LOCALHOST_GRANTS="RELOAD, PROCESS, LOCK TABLES" "${image}" --plugin-load-add=simple_password_check
pass=$(docker logs "$cid" | grep 'GENERATED ROOT PASSWORD' 2>&1)
# trim up until passwod
pass=${pass#*GENERATED ROOT PASSWORD: }
mariadbclient -u root -p"${pass}" -e 'select current_user()'

	docker exec --user mysql -i \
		"$cname" \
		mysql \
		--silent \
		-e "select 'I connect therefore I am'" || die "I'd hoped to work around MDEV-24111"

	grants="$(docker exec --user mysql -i \
		$cname \
		mysql \
		--silent \
		-e show\ grants)"

	# shellcheck disable=SC2016
	[ "${grants//\'/\`}" == 'GRANT RELOAD, PROCESS, LOCK TABLES ON *.* TO `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "I wasn't granted what I was expected"

	killoff

	;&
	mysql_random_password_is_different)

echo -e "Test: second instance of MYSQL_RANDOM_ROOT_PASSWORD has a different password (and mysql@localhost can be created(\n"

runandwait -e MYSQL_RANDOM_ROOT_PASSWORD=1 -e MARIADB_MYSQL_LOCALHOST_USER=1 "${image}" --plugin-load-add=simple_password_check
newpass=$(docker logs "$cid" | grep 'GENERATED ROOT PASSWORD' 2>&1)
# trim up until passwod
newpass=${newpass#*GENERATED ROOT PASSWORD: }
mariadbclient -u root -p"${newpass}" -e 'select current_user()'
killoff

[ "$pass" = "$newpass" ] && die "highly improbable - two consequitive passwords are the same"

	;&
	mysql_root_host_sets_host)

echo -e "Test: MYSQL_ROOT_HOST\n"

runandwait -e  MYSQL_ALLOW_EMPTY_PASSWORD=1  -e MYSQL_ROOT_HOST=apple "${image}" 
ru=$(mariadbclient_unix --skip-column-names -B -u root -e 'select user,host from mysql.user where host="apple"')
[ "${ru}" = '' ] && die 'root@apple not created'
killoff

	;&
	complex_passwords)

echo -e "Test: complex passwords\n"

runandwait -e MYSQL_USER=bob -e MYSQL_PASSWORD=$'\n \' \n' -e MYSQL_ROOT_PASSWORD=$'\n\'\\aa-\x09-zz"_%\n' "${image}"
mariadbclient_unix --skip-column-names -B -u root -p$'\n\'\\aa-\x09-zz"_%\n' -e 'select 1'
mariadbclient_unix --skip-column-names -B -u bob -p$'\n \' \n' -e 'select 1'
killoff

	;&
	mysql_initdb_skip_tzinfo_empty)

echo -e "Test: MYSQL_INITDB_SKIP_TZINFO='' should still load timezones\n"

runandwait -e MYSQL_INITDB_SKIP_TZINFO= -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "${image}" --default-time-zone=Europe/Berlin
tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
[ "${tzcount}" = '0' ] && die "should exist timezones"
[ "$(mariadbclient --skip-column-names -B -u root -e 'SELECT @@time_zone')" != "Europe/Berlin" ] && die "Didn't set timezone to Berlin"
killoff

	;&
	mysql_initdb_skip_tzinfo_no_empty)

echo -e "Test: MYSQL_INITDB_SKIP_TZINFO=1 should not load timezones\n"

runandwait -e MYSQL_INITDB_SKIP_TZINFO=1 -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "${image}"
tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
[ "${tzcount}" = '0' ] || die "timezones shouldn't be loaded - found ${tzcount}"
killoff

	;&
	secrets_via_file)

echo -e "Test: Secrets _FILE vars should be same as env directly\n"

secretdir=$(mktemp -d)
chmod go+rx "${secretdir}"
echo bob > "$secretdir"/pass
echo pluto > "$secretdir"/host
echo titan > "$secretdir"/db
echo ron > "$secretdir"/u
echo scappers > "$secretdir"/p

runandwait \
       	-v "$secretdir":/run/secrets:Z \
	-e MYSQL_ROOT_PASSWORD_FILE=/run/secrets/pass \
	-e MYSQL_ROOT_HOST_FILE=/run/secrets/host \
	-e MYSQL_DATABASE_FILE=/run/secrets/db \
	-e MYSQL_USER_FILE=/run/secrets/u \
	-e MYSQL_PASSWORD_FILE=/run/secrets/p \
	"${image}" 

host=$(mariadbclient_unix --skip-column-names -B -u root -pbob -e 'select host from mysql.user where user="root" and host="pluto"' titan)
[ "${host}" != 'pluto' ] && die 'root@pluto not created'
creation=$(mariadbclient --skip-column-names -B -u ron -pscappers -P 3306 --protocol tcp titan -e "CREATE TABLE landing(i INT)")
[ "${creation}" = '' ] || die 'creation error'
killoff
rm -rf "${secretdir}"

	;&
	docker_entrypint_initdb)

echo -e "Test: docker-entrypoint-initdb.d Initialization order is correct and processed\n"

initdb=$(mktemp -d)
chmod go+rx "${initdb}"
cp -a "$dir"/initdb.d/* "${initdb}"
gzip "${initdb}"/*gz*
xz "${initdb}"/*xz*
zstd "${initdb}"/*zst*

runandwait \
        -v "${initdb}":/docker-entrypoint-initdb.d:Z \
	-e MYSQL_ROOT_PASSWORD=ssh \
	-e MYSQL_DATABASE=titan \
	-e MYSQL_USER=ron \
	-e MYSQL_PASSWORD=scappers \
	"${image}" 

init_sum=$(mariadbclient --skip-column-names -B -u ron -pscappers -P 3306 -h 127.0.0.1  --protocol tcp titan -e "select sum(i) from t1;")
[ "${init_sum}" = '1833' ] || (podman logs m_init; die 'initialization order error')
killoff
rm -rf "${initdb}"


	;&
	prefer_mariadb_names)

echo -e "Test: when provided with MYSQL_ and MARIADB_ names, Prefer MariaDB names\n"

runandwait -e MARIADB_ROOT_PASSWORD=examplepass -e MYSQL_ROOT_PASSWORD=mysqlexamplepass "${image}"
mariadbclient -u root -pexamplepass -e 'select current_user()'
mariadbclient -u root -pwrongpass -e 'select current_user()' || echo 'expected failure of wrong password'
killoff

	;&
	mariadb_allow_empty_root_password_empty)

echo -e "Test: MARIADB_ALLOW_EMPTY_ROOT_PASSWORD Implementation is empty value so this should fail\n"

docker run  --rm  --name "$cname" -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD "$image" || echo 'expected failure MARIADB_ALLOW_EMPTY_ROOT_PASSWORD is empty'

	;&
	mariadb_allow_empty_root_password_not_empty)

echo -e "Test: MARIADB_ALLOW_EMPTY_ROOT_PASSWORD\n"

# +Defaults to clean environment
runandwait -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
mariadbclient -u root -e 'show databases'

othertables=$(mariadbclient -u root --skip-column-names -Be "select group_concat(SCHEMA_NAME) from information_schema.SCHEMATA where SCHEMA_NAME not in ('mysql', 'information_schema', 'performance_schema', 'sys')")
[ "${othertables}" != 'NULL' ] && die "unexpected table(s) $othertables"

otherusers=$(mariadbclient -u root --skip-column-names -Be "select user,host from mysql.user where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'), ('mysql','localhost'))")
[ "$otherusers" != '' ] && die "unexpected users $otherusers"
killoff

	;&
	mariadb_root_password_is_set)

echo -e "Test: MARIADB_ROOT_PASSWORD\n"

runandwait -e MARIADB_ROOT_PASSWORD=examplepass "${image}"
mariadbclient -u root -pexamplepass -e 'select current_user()'
mariadbclient -u root -pwrongpass -e 'select current_user()' || echo 'expected failure' 
killoff

	;&
	mariadb_root_password_is_complex)

echo -e "Test: MARIADB_RANDOM_ROOT_PASSWORD, needs to satisify minimium complexity of simple-password-check plugin\n"

runandwait -e MARIADB_RANDOM_ROOT_PASSWORD=1 "${image}" --plugin-load-add=simple_password_check
pass=$(docker logs "$cid"  2>&1 | grep 'GENERATED ROOT PASSWORD')
# trim up until passwod
pass=${pass#*GENERATED ROOT PASSWORD: }
mariadbclient -u root -p"${pass}" -e 'select current_user()'
killoff

	;&
	mariadb_root_password_is_different)

echo -e "Test: second instance of MARIADB_RANDOM_ROOT_PASSWORD has a different password\n"

runandwait -e MARIADB_RANDOM_ROOT_PASSWORD=1 "${image}" --plugin-load-add=simple_password_check
newpass=$(docker logs "$cid"  2>&1 | grep 'GENERATED ROOT PASSWORD')
# trim up until passwod
newpass=${newpass#*GENERATED ROOT PASSWORD: }
mariadbclient -u root -p"${newpass}" -e 'select current_user()'
killoff

[ "$pass" = "$newpass" ] && die "highly improbable - two consequitive random passwords are the same"

	;&
	mariadb_root_host_sets_host)

echo -e "Test: MARIADB_ROOT_HOST\n"

runandwait -e  MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1  -e MARIADB_ROOT_HOST=apple "${image}"
ru=$(mariadbclient_unix --skip-column-names -B -u root -e 'select user,host from mysql.user where host="apple"')
[ "${ru}" = '' ] && die 'root@apple not created'
killoff

	;&
	mariadb_initdb_skip_tzinfo_empty)

echo -e "Test: MARIADB_INITDB_SKIP_TZINFO=''\n"

runandwait -e MARIADB_INITDB_SKIP_TZINFO= -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
[ "${tzcount}" = '0' ] && die "should exist timezones"

# note uses previous instance
echo -e "Test: default configuration items are present\n"
arg_expected=0
docker exec -i "$cid" my_print_defaults --mysqld |
	{
	while read -r line
	do
		case $line in
		--skip-host-cache|--skip-name-resolve)
			echo "$line" found
			(( arg_expected++ )) || : ;;
		esac
	done
	[ "$arg_expected" -eq 2 ] || die "expected both skip-host-cache and skip-name-resolve"
}
killoff

	;&
	mariadb_initdb_skip_tzinfo_not_empty)

echo -e "Test: MARIADB_INITDB_SKIP_TZINFO=1\n"

runandwait -e MARIADB_INITDB_SKIP_TZINFO=1 -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
[ "${tzcount}" = '0' ] || die "timezones shouldn't be loaded - found ${tzcount}"
killoff

	;&
	jemalloc)

case "$architecture" in
	amd64)
		debarch=x86_64 ;;
	arm64)
		debarch=aarch64 ;;
	ppc64le)
		debarch=powerpc64le ;;
	s390x|i386)
		debarch=$architecture ;;
esac
if [ -n "$debarch" ]
then
	echo -e "Test: jemalloc preload\n"
	runandwait -e LD_PRELOAD="/usr/lib/$debarch-linux-gnu/libjemalloc.so.1 /usr/lib/$debarch-linux-gnu/libjemalloc.so.2" -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
	docker exec -i "$cid" gosu mysql /bin/grep 'jemalloc' /proc/1/maps || die "expected to preload jemalloc"


	killoff
else
	echo -e "Test: jemalloc skipped - unknown arch '$architecture'\n"
fi

	;&
	mariadbupgrade)
	docker volume rm m57 || echo "m57 already cleaned"
	docker volume create m57
	docker pull docker.io/library/mysql:5.7
	runandwait -v m57:/var/lib/mysql:Z -e MYSQL_INITDB_SKIP_TZINFO=1 -e MYSQL_ROOT_PASSWORD=bob docker.io/library/mysql:5.7
	# clean shutdown required
	mariadbclient -u root -pbob -e "set global innodb_fast_shutdown=0;SHUTDOWN"
	while docker exec "$cid" ls -lad /proc/1; do
		sleep 1
	done

	runandwait -e MARIADB_AUTO_UPGRADE=1 -v m57:/var/lib/mysql:Z "${image}"
	
	version=$(mariadbclient --skip-column-names -B -u root -pbob -e "SELECT VERSION()")

	docker exec "$cid" ls -la /var/lib/mysql/system_mysql_backup_unknown_version.sql.zst || die "hopeing for backup file"

	echo "Did the upgrade run?"
	docker logs "$cid" 2>&1 | grep -A 15 'Starting mariadb-upgrade' || die "missing upgrade message"
	echo

	docker exec "$cid" ls -la /var/lib/mysql/

	echo "Final upgrade info reflects current version?"
	docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info || die "missing mysql_upgrade_info on install"
	echo

	upgradeversion=$(docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info)
	# note VERSION() is longer
	[[ $version =~ ^${upgradeversion} ]] || die "upgrade version didn't match"

	echo "fix version to 5.x"
	docker exec "$cid" sed -i -e 's/[0-9]*\(.*\)/5\1/' /var/lib/mysql/mysql_upgrade_info
	docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info
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
	docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info || die "missing mysql_upgrade_info on install"
	upgradeversion=$(docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info)
	[[ $version =~ ^${upgradeversion} ]] || die "upgrade version didn't match current version"
	echo

	echo "Fixing back to 0 minor version"
	docker exec "$cid" sed -i -e 's/[0-9]*-\(MariaDB\)/0-\1/' /var/lib/mysql/mysql_upgrade_info
	upgradeversion=$(docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info)
	killoff

	runandwait -e MARIADB_AUTO_UPGRADE=1 -v m57:/var/lib/mysql:Z "${image}"
	docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info
	newupgradeversion=$(docker exec "$cid" cat /var/lib/mysql/mysql_upgrade_info)
	[ "$upgradeversion" = "$newupgradeversion" ] || die "upgrade versions from mysql_upgrade_info should match"
       	docker logs "$cid" 2>&1 | grep -C 5 'MariaDB upgrade not required' || die 'should not have upgraded'

	killoff
	docker volume rm m57

# Insert new tests above by copying the comments below
#	;&
#	THE_TEST_NAME)

	;;
	*)
	echo "Test $2 not found" >&2
	exit 1
esac
