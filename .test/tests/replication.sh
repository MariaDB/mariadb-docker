#!/bin/bash
# Tests for replication, binlog, and Galera
# Sourced by run.sh — do not execute directly
# shellcheck disable=SC2154

test_binlog() {
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
		-e MARIADB_HEALTHCHECK_GRANTS="REPLICA MONITOR" \
		--network=container:"$master_host" \
		--health-cmd='healthcheck.sh --replication_io --replication_sql --replication_seconds_behind_master=0 --replication' \
		--health-interval=3s \
		"$image" --server-id=2 --port 3307 --require-secure-transport=1)

	c="${DOCKER_LIBRARY_START_TIMEOUT:-10}"
	until docker exec "$cid" healthcheck.sh --connect --replication_io --replication_sql --replication_seconds_behind_master=0 --replication || [ "$c" -eq 0 ]; do
		sleep 1
		c=$(( c - 1 ))
	done
	count_replica=$(mariadbclient_tcp -u bob -proger rabbit --batch --skip-column-names -e 'select sum(i) from t1')
	if [ "$count_primary" != "$count_replica" ]; then
		cid=$cid_primary killoff
		die "Table contents didn't match on replica"
	fi
	killoff
	cid=$master_host
	killoff
}

test_validate_master_env() {
	echo -e "Test: Expect failure for master; MARIADB_REPLICATION_USER without MARIADB_REPLICATION_PASSWORD or MARIADB_REPLICATION_PASSWORD_HASH specified\n"

	cname="mariadb-container-replica-fail-to-start-options-$RANDOM-$RANDOM"
	docker run --rm --name "$cname" \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		-e MARIADB_REPLICATION_USER="repl" \
		"$image" \
		&& die "$cname should fail with incomplete options"
	return 0
}

test_validate_replica_env() {
	echo -e "Test: Expect failure for replica mode without MARIADB_REPLICATION_USER specified\n"

	cname="mariadb-container-replica-fail-to-start-options-$RANDOM-$RANDOM"
	docker run --rm --name "$cname" \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		-e MARIADB_MASTER_HOST="ok" \
		"$image" \
		&& die "$cname should fail with incomplete options"
	cname=
	return 0
}

test_replication() {
	echo -e "Test: Replica container can be initialized with environment variables when MARIADB_REPLICATION_PASSWORD is set\n"

	checkReplication 'MARIADB_REPLICATION_PASSWORD'
}

test_replication_password_hash() {
	echo -e "Test: Replica container can be initialized with environment variables when MARIADB_REPLICATION_PASSWORD_HASH is set\n"

	checkReplication 'MARIADB_REPLICATION_PASSWORD_HASH'
}

test_galera_mariadbbackup() {
	echo -e "Test: Galera SST mechanism mariadb-backup\n"

	galera_sst mariabackup
}

test_galera_sst_rsync() {
	echo -e "Test: Galera SST mechanism rsync\n"

	galera_sst rsync
}
