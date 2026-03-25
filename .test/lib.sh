#!/bin/bash
# Shared test utilities for MariaDB Docker image tests
# Sourced by run.sh — do not execute directly

set -eo pipefail

# Variables set by run.sh (image/dir before sourcing, architecture/galera after)
: "${image:?}" "${dir:?}"
declare -g image dir architecture galera

# Global state
cid=""
cname=""
master_host=""
netid=""
tmpvol=""
mariadb=mariadb

# Cleanup helpers

killoff() {
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

die() {
	[ -n "$cid" ] && docker logs "$cid"
	[ -n "$tmpvol" ] && docker rm "$tmpvol"
	[ -n "$master_host" ] && docker logs "$master_host"
	killoff
	echo "$@" >&2
	exit 1
}

# Container lifecycle

runandwait() {
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
	set +e +o pipefail
	while [ "$waiting" -gt 0 ]; do
		(( waiting-- ))
		sleep 1
		if ! docker exec -i "$cid" "$mariadb" -h localhost --protocol tcp -P "$port_int" -e 'select 1' 2>&1 | grep -F "Can't connect" > /dev/null; then
			break
		fi
	done
	set -eo pipefail
	if [ "$waiting" -eq 0 ]; then
		die 'timeout'
	fi
}

# Client wrappers

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

# Assertions / checks

checkUserExistInMariaDB() {
	if [ -z "$1" ]; then
		return 1
	fi

	local user
	user=$(mariadbclient --user root ${2:+--password=$2} -e "SELECT User FROM mysql.global_priv where User='$1';")
	if [ -z "$user" ]; then
		return 1
	fi

	return 0
}

# Reusable test building blocks

checkReplication() {
	mariadb_replication_user='foo'
	local pass_str=
	local pass=
	if [ "$1" = 'MARIADB_REPLICATION_PASSWORD_HASH' ]; then
		pass_str=MARIADB_REPLICATION_PASSWORD_HASH='*0FD9A3F0F816D076CF239580A68A1147C250EB7B'
		pass='jane'
	else
		pass_str='MARIADB_REPLICATION_PASSWORD=foo123'
		pass='foo123'
	fi

	netid="mariadbnetwork$RANDOM"
	docker network create "$netid"

	rootpass=consistent_and_checkcheckable
	runandwait \
		--network "$netid" \
		-e MARIADB_REPLICATION_USER="$mariadb_replication_user" \
		-e "$pass_str" \
		-e MARIADB_DATABASE=replcheck \
		-e MARIADB_ROOT_PASSWORD="${rootpass}" \
		"$image" --server-id=3000 --log-bin --log-basename=my-mariadb

	if checkUserExistInMariaDB $mariadb_replication_user "${rootpass}"; then
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
			-e MARIADB_HEALTHCHECK_GRANTS="REPLICA MONITOR" \
			--health-cmd='healthcheck.sh --connect --innodb-initialized --replication_io --replication_sql --replication_seconds_behind_master=0 --replication' \
			--health-interval=3s \
			"$image" --server-id=3001 --port "${port}"
		unset port

		c="${DOCKER_LIBRARY_START_TIMEOUT:-10}"
		until docker exec "$cid" healthcheck.sh --connect --replication_io --replication_sql --replication_seconds_behind_master=0 --replication || [ "$c" -eq 0 ]; do
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

galera_sst() {
	if [ "$galera" -eq 0 ]; then
		echo No galera
		return 0
	fi
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
		--env MARIADB_ROOT_PASSWORD=secret --env MARIADB_DATABASE=test --env MARIADB_USER=test --env MARIADB_PASSWORD=test \
		"${image}" \
		--wsrep-new-cluster --wsrep-provider=/usr/lib/libgalera_smm.so --wsrep_cluster_address=gcomm://"$cname" --binlog_format=ROW --innodb_autoinc_lock_mode=2 --wsrep_on=ON --wsrep_sst_method="$sst" --wsrep_sst_auth=root:secret
	master_host=$cid
	unset cname
	ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")
	DOCKER_LIBRARY_START_TIMEOUT=$(( ${DOCKER_LIBRARY_START_TIMEOUT:-10} * 7 )) runandwait \
		--network "$netid" \
		--env MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}" \
		--wsrep-provider=/usr/lib/libgalera_smm.so --wsrep_cluster_address=gcomm://"$ip" --binlog_format=ROW --innodb_autoinc_lock_mode=2 --wsrep_on=ON --wsrep_sst_method="$sst" --wsrep_sst_auth=root:secret

	v=$(mariadbclient -u root -psecret -e 'select VARIABLE_VALUE from information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME="WSREP_LOCAL_STATE"' || :)

	waiting=${DOCKER_LIBRARY_START_TIMEOUT:-10}
	set +e +o pipefail
	while [ "$waiting" -gt 0 ] && [ "$v" != 4 ]; do
		(( waiting-- ))
		sleep 1
		v=$(mariadbclient -u root -psecret -e 'select VARIABLE_VALUE from information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME="WSREP_LOCAL_STATE"' || :)
	done
	set -eo pipefail
	if [ "$v" != 4 ]; then
		die 'timeout'
	fi

	killoff
}

# initdb helpers

prepare_initdb() {
	local initdb
	initdb=$(mktemp -d)
	chmod go+rx "${initdb}"
	cp -a "$dir"/initdb.d/* "${initdb}"
	chmod -R go+rX "${initdb}"
	gzip "${initdb}"/*gz*
	xz "${initdb}"/*xz*
	zstd "${initdb}"/*zst*
	echo "$initdb"
}
