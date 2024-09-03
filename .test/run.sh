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
	if [ -n "$cid" ]; then
	      docker kill "$cid" > /dev/null || true
	fi
	sleep 2
	if [ -n "$cid" ]; then
	       docker rm -v -f "$cid" > /dev/null || true
	fi
	cid=""
	if [ -n "$master_host" ]; then
		cid=$master_host
		master_host=""
		killoff
	fi
	if [ -n "$netid" ]; then
		docker network rm "$netid"
		netid=
	fi
}

die()
{
	[ -n "$cid" ] && docker logs "$cid"
	[ -n "$tmpvol" ] && docker rm "$tmpvol"
	[ -n "$master_host" ] && docker logs "$master_host"
	killoff
        echo "$@" >&2
        exit 1
}
trap "killoff" EXIT

mariadb=mariadb
RPL_MONITOR="REPLICA MONITOR"
v=$(docker run --rm "$image" mariadb --version)
if [[ $v =~ Distrib\ 10.4 ]]; then
	# the new age hasn't begun yet
	RPL_MONITOR="REPLICATION CLIENT"
fi

runandwait()
{
	local port_int
	if [ -z "$cname" ]; then
		cname="mariadbcontainer$RANDOM"
	fi
	if [ -z "$port" ]; then
		cid="$(
			docker run -d \
				--name "$cname" --rm --publish 3306 "$@"
		)"
		port_int=3306
	else
		cid="$(
			docker run -d \
				--name "$cname" --rm "$@"
		)"
		port_int=$port
	fi
	waiting=${DOCKER_LIBRARY_START_TIMEOUT:-15}
	echo "waiting to start..."
	set +e +o pipefail +x
	while [ "$waiting" -gt 0 ]
	do
		(( waiting-- ))
		sleep 1
		if ! docker exec -i "$cid" "$mariadb" -h localhost --protocol tcp -P "$port_int" -e 'select 1' 2>&1 | grep -F "Can't connect" > /dev/null
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

mariadbclient_tcp() {
	docker exec -i \
		"$cname" \
		$mariadb \
		--host 127.0.0.1 \
		--protocol tcp \
		--silent \
		"$@"
}

mariadbclient() {
	docker exec -i \
		"$cname" \
		$mariadb \
		--silent \
		"$@"
}

checkUserExistInMariaDB() {
	if [ -z "$1" ] ; then
		return 1
	fi

	local user
	user=$(mariadbclient --user root ${2:+--password=$2} -e "SELECT User FROM mysql.global_priv where User='$1';")
	if [ -z "$user" ] ; then
		return 1
	fi

	return 0
}

checkReplication() {
	mariadb_replication_user='foo'
	local pass_str=
	local pass=
	if [ "$1" = 'MARIADB_REPLICATION_PASSWORD_HASH' ] ; then
		pass_str=MARIADB_REPLICATION_PASSWORD_HASH='*0FD9A3F0F816D076CF239580A68A1147C250EB7B'
		pass='jane'
	else
		pass_str='MARIADB_REPLICATION_PASSWORD=foo123'
		pass='foo123'
	fi

	netid="mariadbnetwork$RANDOM"
	docker network create "$netid"

	# When MARIADB_REPLICATION_HOST is not specified as env, and MARIADB_REPLICATION_USER exists, then considered as master container.
	rootpass=consistent_and_checkcheckable
	runandwait \
		--network "$netid" \
		-e MARIADB_REPLICATION_USER="$mariadb_replication_user" \
		-e "$pass_str" \
		-e MARIADB_DATABASE=replcheck \
		-e MARIADB_ROOT_PASSWORD="${rootpass}" \
		"$image" --server-id=3000 --log-bin --log-basename=my-mariadb

	# Checks $mariadb_replication_user get created or not
	if checkUserExistInMariaDB $mariadb_replication_user  "${rootpass}"; then
		grants=$(mariadbclient_tcp -u $mariadb_replication_user -p$pass -e "SHOW GRANTS")
		# shellcheck disable=SC2076
		[[ "${grants/SLAVE/REPLICA}" =~ "GRANT REPLICATION REPLICA ON *.* TO \`$mariadb_replication_user\`@\`%\`" ]] || die "I wasn't created how I was expected: got $grants"

		mariadbclient_tcp -u root --password="$rootpass" --batch --skip-column-names -e 'create table t1(i int)' replcheck
		readarray -t vals < <(mariadbclient_tcp --password="$rootpass" -u root --batch --skip-column-names -e 'show master status\G' replcheck)
		lastfile="${vals[1]}"
		pos="${vals[2]}"
		[[ "$lastfile" = my-mariadb-bin.00000[12] ]] || die "too many binlog files"
		[ "$pos" -lt 500 ] || die 'binary log too big'
		docker exec "$cid" ls -la /var/lib/mysql/my-mariadb-bin.000001
		docker exec "$cid" sh -c '[ $(wc -c < /var/lib/mysql/my-mariadb-bin.000001 ) -gt 2500 ]' && die 'binary log 1 too big'
		docker exec "$cid" sh -c "[ \$(wc -c < /var/lib/mysql/$lastfile ) -gt $pos ]" && die 'binary log 2 too big'

		master_host=$cname
		unset cname
		master_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$master_host")
		port=3307
		runandwait \
			--network "$netid" \
			-e MARIADB_MASTER_HOST="$master_ip" \
		        -e MARIADB_ROOT_PASSWORD="${rootpass}" \
			-e MARIADB_REPLICATION_USER="$mariadb_replication_user" \
			-e MARIADB_REPLICATION_PASSWORD="$pass" \
			-e MARIADB_HEALTHCHECK_GRANTS="${RPL_MONITOR}" \
			--health-cmd='healthcheck.sh --connect --innodb-initialized --replication_io --replication_sql --replication_seconds_behind_master=0 --replication' \
			--health-interval=3s \
			"$image" --server-id=3001 --port "${port}"
		unset port

		c="${DOCKER_LIBRARY_START_TIMEOUT:-10}"
		until docker exec "$cid" healthcheck.sh --connect --replication_io --replication_sql --replication_seconds_behind_master=0 --replication || [ "$c" -eq 0 ]
		do
			sleep 1
			c=$(( c - 1 ))
		done

		docker exec --user mysql -i \
			"$cname" \
			$mariadb --defaults-file=/var/lib/mysql/.my-healthcheck.cnf \
			-e 'SHOW SLAVE STATUS\G' || die 'error examining replica status'

		mariadbclient -u root --password="$rootpass" --batch --skip-column-names replcheck -e 'show create table t1;' || die 'sample table not replicated'

		killoff
	else
		die "User $mariadb_replication_user did not get created for replication mode master"
	fi
}

galera_sst()
{
        if [ "$architecture" != amd64 ]; then
		echo test is too slow if not run natively
		return 0
	fi
	sst=$1

	netid="mariadbnetwork$RANDOM"
	docker network create "$netid"

	cname="mariadbcontainer_donor$RANDOM"
	runandwait \
		--network "$netid" \
		--env MARIADB_ROOT_PASSWORD=secret  --env MARIADB_DATABASE=test  --env MARIADB_USER=test --env MARIADB_PASSWORD=test \
		"${image}"\
		--wsrep-new-cluster --wsrep-provider=/usr/lib/libgalera_smm.so --wsrep_cluster_address=gcomm://"$cname" --binlog_format=ROW --innodb_autoinc_lock_mode=2 --wsrep_on=ON --wsrep_sst_method="$sst" --wsrep_sst_auth=root:secret
	master_host=$cid
	unset cname
	ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")
	DOCKER_LIBRARY_START_TIMEOUT=$(( ${DOCKER_LIBRARY_START_TIMEOUT:-10} * 7 )) runandwait \
		--network "$netid" \
		--env MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}" \
		--wsrep-provider=/usr/lib/libgalera_smm.so  --wsrep_cluster_address=gcomm://"$ip" --binlog_format=ROW --innodb_autoinc_lock_mode=2 --wsrep_on=ON --wsrep_sst_method="$sst" --wsrep_sst_auth=root:secret

	v=$(mariadbclient -u root -psecret -e 'select VARIABLE_VALUE from information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME="WSREP_LOCAL_STATE"' || :)

	waiting=${DOCKER_LIBRARY_START_TIMEOUT:-10}
	set +e +o pipefail +x
	while [ "$waiting" -gt 0 ] && [ "$v" != 4 ]
	do
		(( waiting-- ))
		sleep 1
		v=$(mariadbclient -u root -psecret -e 'select VARIABLE_VALUE from information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME="WSREP_LOCAL_STATE"' || :)
        done
	set -eo pipefail -x
	if [ "$v" != 4 ]
	then
		die 'timeout'
	fi

	killoff
}

case ${2:-all} in
	all|required_password)

echo -e "Test: expect Failure - none of MYSQL_ALLOW_EMPTY_PASSWORD, MYSQL_RANDOM_ROOT_PASSWORD, MYSQL_ROOT_PASSWORD\n"

cname="mariadb-container-fail-to-start-options-$RANDOM-$RANDOM"
docker run --name "$cname" --rm "$image" 2>&1 && die "$cname should fail with unspecified option"

	;&
	mysql_allow_empty_password_is_empty)

echo -e "Test: MYSQL_ALLOW_EMPTY_PASSWORD Implementation is empty value so this should fail\n"
docker run  --rm  --name "$cname" -e MYSQL_ALLOW_EMPTY_PASSWORD  "$image" && die "$cname should fail with empty MYSQL_ALLOW_EMPTY_PASSWORD"
echo 'expected failure of empty MYSQL_ALLOW_EMPTY_PASSWORD'

	;&
	mysql_allow_empty_password_is_clean)

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

	;&
	mysql_root_password_is_set)

	echo -e "Test: MYSQL_ROOT_PASSWORD and mysql@localhost user\n"

	runandwait -e MYSQL_ROOT_PASSWORD=examplepass -e MARIADB_MYSQL_LOCALHOST_USER=1 "${image}"
	mariadbclient -u root -pexamplepass -e 'select current_user()'
	mariadbclient -u root -pwrongpass -e 'select current_user()' || echo 'expected failure'

	otherusers=$(mariadbclient -u root -pexamplepass --skip-column-names -Be "select user,host from mysql.global_priv where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'), ('mysql','localhost'), ('healthcheck', '::1'), ('healthcheck', '127.0.0.1'), ('healthcheck', 'localhost'))")
	[ "$otherusers" != '' ] && die "unexpected users $otherusers"

	createuser=$(docker exec --user mysql -i \
		"$cname" \
		$mariadb \
		--silent \
		-e "show create user")
	# shellcheck disable=SC2016
	[ "${createuser//\'/\`}" == 'CREATE USER `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "mysql@localhost wasn't created how I was expected"

	grants="$(docker exec --user mysql -i \
		"$cname" \
		$mariadb \
		--silent \
		-e show\ grants)"

	# shellcheck disable=SC2016
	[ "${grants//\'/\`}" == 'GRANT USAGE ON *.* TO `mysql`@`localhost` IDENTIFIED VIA unix_socket' ] || die "mysql@localhost wasn't granted what I was expected"

	createuser=$(docker exec --user mysql -i \
		"$cname" \
		$mariadb --defaults-file=/var/lib/mysql/.my-healthcheck.cnf \
		--silent \
		-e "show create user")
	# shellcheck disable=SC2016,SC2076
	[[ "${createuser//\'/\`}" =~ 'CREATE USER `healthcheck`@`localhost` IDENTIFIED' ]] || \
		[[ "${createuser//\'/\`}" =~ 'CREATE USER `healthcheck`@`::1` IDENTIFIED' ]] || \
		[[ "${createuser//\'/\`}" =~ 'CREATE USER `healthcheck`@`127.0.0.1` IDENTIFIED' ]] || die "healthcheck wasn't created how I was expected"

	grants="$(docker exec --user mysql -i \
		"$cname" \
		$mariadb --defaults-file=/var/lib/mysql/.my-healthcheck.cnf \
		--silent \
		-e show\ grants)"

	[[ "${grants//\'/\`}" =~ GRANT\ USAGE\ ON\ *.*\ TO\ \`healthcheck\`@\`localhost\` ]] || \
		[[ "${grants//\'/\`}" =~ GRANT\ USAGE\ ON\ *.*\ TO\ \`healthcheck\`@\`::1\` ]] || \
		[[ "${grants//\'/\`}" =~ GRANT\ USAGE\ ON\ *.*\ TO\ \`healthcheck\`@\`127.0.0.1\` ]] || die "healthcheck wasn't granted what I was expected"
	killoff

	;&
	mysql_random_password_is_complex)

echo -e "Test: MYSQL_RANDOM_ROOT_PASSWORD, needs to satisfy minimum complexity of simple-password-check plugin and old-mode=''\n"

runandwait -e MYSQL_RANDOM_ROOT_PASSWORD=1 -e MARIADB_MYSQL_LOCALHOST_USER=1 -e MARIADB_MYSQL_LOCALHOST_GRANTS="RELOAD, PROCESS, LOCK TABLES" \
	"${image}" --plugin-load-add=simple_password_check --old-mode=""
pass=$(docker logs "$cid" | grep 'GENERATED ROOT PASSWORD' 2>&1)
# trim up until passwod
pass=${pass#*GENERATED ROOT PASSWORD: }
mariadbclient -u root -p"${pass}" -e 'select current_user()'

	docker exec --user mysql -i \
		"$cname" \
		$mariadb \
		--silent \
		-e "select 'I connect therefore I am'" || die "I'd hoped to work around MDEV-24111"

	grants="$(docker exec --user mysql -i \
		"$cname" \
		$mariadb \
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

[ "$pass" = "$newpass" ] && die "highly improbable - two consecutive passwords are the same"

	;&
	mysql_root_host_sets_host)

echo -e "Test: MYSQL_ROOT_HOST\n"

runandwait -e  MYSQL_ALLOW_EMPTY_PASSWORD=1  -e MYSQL_ROOT_HOST=apple "${image}"
ru=$(mariadbclient --skip-column-names -B -u root -e 'select user,host from mysql.global_priv where host="apple"')
[ "${ru}" = '' ] && die 'root@apple not created'
killoff

	;&
	mysql_root_host_localhost)

echo -e "Test: MYSQL_ROOT_HOST=localhost\n"

runandwait -e  MARIADB_ROOT_PASSWORD=bob  -e MYSQL_ROOT_HOST=localhost "${image}"
ru=$(mariadbclient --skip-column-names -B -u root -pbob -e 'select user,host from mysql.global_priv where user="root" and host="localhost"')
[ "${ru}" = '' ] && die 'root@localhost not created'
killoff

	;&
	complex_passwords)

echo -e "Test: complex passwords\n"

runandwait -e MYSQL_USER=bob -e MYSQL_PASSWORD=$'\n \' \n' -e MYSQL_ROOT_PASSWORD=$'\n\'\\aa-\x09-zz"_%\n' \
	-e MARIADB_REPLICATION_USER="foo" \
	-e MARIADB_REPLICATION_PASSWORD=$'\n\'\\aa-\x09-zz"_%\n' \
	"${image}"
mariadbclient --skip-column-names -B -u root -p$'\n\'\\aa-\x09-zz"_%\n' -e 'select 1'
mariadbclient --skip-column-names -B -u foo -p$'\n\'\\aa-\x09-zz"_%\n' -e 'select 1'
mariadbclient --skip-column-names -B -u bob -p$'\n \' \n' -e 'select 1'
killoff

	;&
	mysql_initdb_skip_tzinfo_empty)

echo -e "Test: MYSQL_INITDB_SKIP_TZINFO='' should still load timezones\n"

# ONLY_FULL_GROUP_BY - test for MDEV-29347
runandwait -e MYSQL_INITDB_SKIP_TZINFO= -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "${image}" --default-time-zone=Europe/Berlin --sql-mode=ONLY_FULL_GROUP_BY
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
echo '*D87991C62A9CAEDC4AE0F608F19173AC7E614952' > "$secretdir"/p

tmpvol=v$RANDOM
docker volume create "$tmpvol"
# any container will work with tar in it, we may well use the image we have
(cd "$secretdir" ; tar -cf - .) | docker run --rm --volume "$tmpvol":/v --user root -i "${image}" tar -xf - -C /v
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
[ "${init_sum}" = '1833' ] || die 'initialization order error'
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

otherusers=$(mariadbclient -u root --skip-column-names -Be "select user,host from mysql.global_priv where (user,host) not in (('root', 'localhost'), ('root', '%'), ('mariadb.sys', 'localhost'), ('mysql','localhost'), ('healthcheck', '::1'), ('healthcheck', '127.0.0.1'), ('healthcheck', 'localhost'))")
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

echo -e "Test: MARIADB_RANDOM_ROOT_PASSWORD, needs to satisfy minimum complexity of simple-password-check plugin\n"

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
# trim up until password
newpass=${newpass#*GENERATED ROOT PASSWORD: }
mariadbclient -u root -p"${newpass}" -e 'select current_user()'
killoff

[ "$pass" = "$newpass" ] && die "highly improbable - two consecutive random passwords are the same"

	;&
	mariadb_root_host_sets_host)

echo -e "Test: MARIADB_ROOT_HOST\n"

runandwait -e  MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1  -e MARIADB_ROOT_HOST=apple "${image}"
ru=$(mariadbclient --skip-column-names -B -u root -e 'select user,host from mysql.global_priv where host="apple"')
[ "${ru}" = '' ] && die 'root@apple not created'
killoff

	;&
	mariadb_initdb_skip_tzinfo_empty)

echo -e "Test: MARIADB_INITDB_SKIP_TZINFO=''\n"

runandwait -e MARIADB_INITDB_SKIP_TZINFO= -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
tzcount=$(mariadbclient --skip-column-names -B -u root -e "SELECT COUNT(*) FROM mysql.time_zone")
[ "${tzcount}" = '0' ] && die "should exist time zones"

# note uses previous instance
echo -e "Test: default configuration items are present\n"
arg_expected=0
docker exec -i "$cid" my_print_defaults --mysqld |
	{
	while read -r line
	do
		case $line in
		--host-cache-size=0|--skip-name-resolve)
			echo "$line" found
			(( arg_expected++ )) || : ;;
		esac
	done
	[ "$arg_expected" -eq 2 ] || die "expected both host-cache-size=0 and skip-name-resolve"
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
	s390x|i386|*)
		debarch=$architecture ;;
esac
if [ -n "$debarch" ]
then
	echo -e "Test: jemalloc preload\n"
	runandwait -e LD_PRELOAD="/usr/lib/$debarch-linux-gnu/libjemalloc.so.1 /usr/lib/$debarch-linux-gnu/libjemalloc.so.2 /usr/lib64/libjemalloc.so.2" -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
	docker exec -i --user mysql "$cid" /bin/grep 'jemalloc' /proc/1/maps || die "expected to preload jemalloc"


	killoff
else
	echo -e "Test: jemalloc skipped - unknown arch '$architecture'\n"
fi

	;&
	mariadbupgrade)
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

	;&
	encryption)

	echo -e "Test: Startup using encryption \n"
	runandwait -v "${dir}"/encryption_conf/:/etc/mysql/conf.d/:z -v "${dir}"/encryption:/etc/encryption/:z -v "${dir}"/initenc:/docker-entrypoint-initdb.d/:z \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=123-databasename-456 -e MARIADB_USER=123-username-456 -e MARIADB_PASSWORD=hope "${image}"
	mariadbclient -u root -e 'SELECT * FROM information_schema.innodb_tablespaces_encryption' || die 'Failed to start container'


	cnt=$(mariadbclient --skip-column-names -B -u root -e 'SELECT COUNT(*) FROM information_schema.innodb_tablespaces_encryption')
	[ "$cnt" -gt 0 ] || die 'Failed to initialize encryption on initialization'
	killoff
	;&
        binlog)

	echo -e "Test: Ensure time zone info isn't written to binary log\n"

	runandwait \
		-v "${dir}"/initdb.d:/docker-entrypoint-initdb.d:Z \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		-e MARIADB_USER=bob \
		-e MARIADB_PASSWORD=roger \
		-e MARIADB_DATABASE=rabbit \
		-e MARIADB_REPLICATION_USER="repluser" \
		-e MARIADB_REPLICATION_PASSWORD="replpassword" \
		"${image}" --log-bin --log-basename=my-mariadb
	readarray -t vals < <(mariadbclient -u root --batch --skip-column-names -e 'show master status\G')
	lastfile="${vals[1]}"
	pos="${vals[2]}"
	[[ "$lastfile" = my-mariadb-bin.00000[12] ]] || die "too many binlog files"
	[ "$pos" -lt 500 ] || die 'binary log too big'
	docker exec "$cid" ls -la /var/lib/mysql/my-mariadb-bin.000001
	docker exec "$cid" sh -c '[ $(wc -c < /var/lib/mysql/my-mariadb-bin.000001 ) -gt 2500 ]' && die 'binary log 1 too big'
	docker exec "$cid" sh -c "[ \$(wc -c < /var/lib/mysql/$lastfile ) -gt $pos ]" && die 'binary log 2 too big'

	cid_primary=$cid
	count_primary=$(mariadbclient -u bob -proger rabbit --batch --skip-column-names -e 'select sum(i) from t1')

	echo -e "Test: Replica container can be initialized with same contents\n"

	master_host=$cname
	cname="mariadb-container-$RANDOM-$RANDOM"
	cid=$(docker run \
		-d \
		--rm \
		--name "$cname" \
		-e MARIADB_MASTER_HOST="$master_host" \
		-e MARIADB_REPLICATION_USER="repluser" \
		-e MARIADB_REPLICATION_PASSWORD="replpassword" \
		-e MARIADB_RANDOM_ROOT_PASSWORD=1 \
		-e MARIADB_HEALTHCHECK_GRANTS="${RPL_MONITOR}" \
		--network=container:"$master_host" \
		--health-cmd='healthcheck.sh --replication_io --replication_sql --replication_seconds_behind_master=0 --replication' \
		--health-interval=3s \
		"$image" --server-id=2 --port 3307 --require-secure-transport=1)

	c="${DOCKER_LIBRARY_START_TIMEOUT:-10}"
	until docker exec "$cid" healthcheck.sh --connect --replication_io --replication_sql --replication_seconds_behind_master=0 --replication || [ "$c" -eq 0 ]
	do
		sleep 1
		c=$(( c - 1 ))
	done
	count_replica=$(mariadbclient_tcp -u bob -proger rabbit --batch --skip-column-names -e 'select sum(i) from t1')
	if [ "$count_primary" != "$count_replica" ];
	then
		cid=$cid_primary killoff
		die "Table contents didn't match on replica"
	fi
	killoff
	cid=$master_host
	killoff

	;&
	validate_master_env)

	echo -e "Test: Expect failure for master; MARIADB_REPLICATION_USER without MARIADB_REPLICATION_PASSWORD or MARIADB_REPLICATION_PASSWORD_HASH specified\n"
	cname="mariadb-container-replica-fail-to-start-options-$RANDOM-$RANDOM"
	docker run  --rm  --name "$cname" \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		-e MARIADB_REPLICATION_USER="repl" \
		"$image" \
		&& die "$cname should fail with incomplete options" 

	;&
	validate_replica_env)

	echo -e "Test: Expect failure for replica mode without MARIADB_REPLICATION_USER specified\n"
	cname="mariadb-container-replica-fail-to-start-options-$RANDOM-$RANDOM"
	docker run  --rm  --name "$cname" \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		-e MARIADB_MASTER_HOST="ok" \
		"$image" \
		&& die "$cname should fail with incomplete options" 

	cname=

	;&
	replication)

	echo -e "Test: Replica container can be initialized with environment variables when MARIADB_REPLICATION_PASSWORD is set\n"

	checkReplication 'MARIADB_REPLICATION_PASSWORD'

	;&
	replication_password_hash)

	echo -e "Test: Replica container can be initialized with environment variables when MARIADB_REPLICATION_PASSWORD_HASH is set\n"

	checkReplication 'MARIADB_REPLICATION_PASSWORD_HASH'

	;&
	password_hash)

	echo -e "Test: create user passwords using password hash\n"

initdb=$(mktemp -d)
chmod go+rx "${initdb}"
cp -a "$dir"/initdb.d/* "${initdb}"
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

	init_sum=$(mariadbclient --skip-column-names -B -u henry -pjane -P 3306 -h 127.0.0.1  --protocol tcp neptune -e "select sum(i) from t1;")
	[ "${init_sum}" = '1833' ] || die 'initialization order error'
	killoff
	rm -rf "${initdb}"

	;&
	galera_mariadbbackup)

	echo -e "Test: Galera SST mechanism mariadb-backup\n"

	galera_sst mariabackup

	;&
	galera_sst_rsync)

	echo -e "Test: Galera SST mechanism rsync\n"

	galera_sst rsync

	# TODO fix - failing to do the authentication correctly of wsrep_sst_auth - Access denied on mysql usage within SST script
	#;&
	#galera_sst_mariadbdump)
	#echo -e "Test: Galera SST mechanism mariadb-dump\n"
	#
	#galera_sst mysqldump

	;&
	backup_restore)

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

	# ERROR 1226 (42000) at line 1: User '\''healthcheck'\'' has exceeded the '\''max_queries_per_hour'\'' resource (current value: 1)'
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

# Insert new tests above by copying the comments below
#	;&
#	THE_TEST_NAME)
#	echo -e "Test: DESCRIPTION\n"

	;;
	*)
	echo "Test $2 not found" >&2
	exit 1
esac

echo "Tests finished"
