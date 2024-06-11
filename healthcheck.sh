#!/bin/bash
#
# Healthcheck script for MariaDB
#
# Runs various tests on the MariaDB server to check its health. Pass the tests
# to run as arguments. If all tests succeed, the server is considered healthy,
# otherwise it's not.
#
# Arguments are processed in strict order. Set replication_* options before
# the --replication option. This allows a different set of replication checks
# on different connections.
#
# --su{=|-mysql} is option to run the healthcheck as a different unix user.
# Useful if mysql@localhost user exists with unix socket authentication
# Using this option disregards previous options set, so should usually be the
# first option.
#
# Some tests require SQL privileges.
#
# TEST                      MINIMUM GRANTS REQUIRED
# connect                   none*
# innodb_initialized        USAGE
# innodb_buffer_pool_loaded USAGE
# galera_online             USAGE
# galera_ready              USAGE
# replication               REPLICATION_CLIENT (<10.5)or REPLICA MONITOR (10.5+)
# mariadbupgrade            none, however unix user permissions on datadir
#
# The SQL user used is the default for the mysql client. This can be the unix user
# if no user(or password) is set in the [mariadb-client] section of a configuration
# file. --defaults-{file,extra-file,group-suffix} can specify a file/configuration
# different from elsewhere.
#
# Note * though denied error message will result in error log without
#      any permissions.

set -eo pipefail

_process_sql()
{
	mysql ${nodefaults:+--no-defaults} \
		${def['file']:+--defaults-file=${def['file']}} \
		${def['extra_file']:+--defaults-extra-file=${def['extra_file']}} \
		${def['group_suffix']:+--defaults-group-suffix=${def['group_suffix']}} \
		--skip-ssl --skip-ssl-verify-server-cert \
		-B "$@"
}

# TESTS


# CONNECT
#
# Tests that a connection can be made over TCP, the final state
# of the entrypoint and is listening. The authentication used
# isn't tested.
connect()
{
	set +e +o pipefail
	# (on second extra_file)
	# shellcheck disable=SC2086
	mysql ${nodefaults:+--no-defaults} \
		${def['file']:+--defaults-file=${def['file']}} \
		${def['extra_file']:+--defaults-extra-file=${def['extra_file']}}  \
		${def['group_suffix']:+--defaults-group-suffix=${def['group_suffix']}}  \
		--skip-ssl --skip-ssl-verify-server-cert \
		-h localhost --protocol tcp -e 'select 1' 2>&1 \
		| grep -qF "Can't connect"
	local ret=${PIPESTATUS[1]}
	set -eo pipefail
	if (( "$ret" == 0 )); then
		# grep Matched "Can't connect" so we fail
		return 1
	fi
	return 0
}

# INNODB_INITIALIZED
#
# This tests that the crash recovery of InnoDB has completed
# along with all the other things required to make it to a healthy
# operational state. Note this may return true in the early
# states of initialization. Use with a connect test to avoid
# these false positives.
innodb_initialized()
{
	local s
	s=$(_process_sql --skip-column-names -e "select 1 from information_schema.ENGINES WHERE engine='innodb' AND support in ('YES', 'DEFAULT', 'ENABLED')")
	[ "$s" == 1 ]
}

# INNODB_BUFFER_POOL_LOADED
#
# Tests the load of the innodb buffer pool as been complete
# implies innodb_buffer_pool_load_at_startup=1 (default), or if
# manually SET innodb_buffer_pool_load_now=1
innodb_buffer_pool_loaded()
{
	local s
	s=$(_process_sql --skip-column-names -e "select VARIABLE_VALUE from information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_load_status'")
	if [[ $s =~ 'load completed' ]]; then
		return 0
	fi
	return 1
}

# GALERA_ONLINE
#
# Tests that the galera node is in the SYNCed state
galera_online()
{
	local s
	s=$(_process_sql --skip-column-names -e "select VARIABLE_VALUE from information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='WSREP_LOCAL_STATE'")
	# 4 from https://galeracluster.com/library/documentation/node-states.html#node-state-changes
	# not https://xkcd.com/221/
	if [[ $s -eq 4 ]]; then
		return 0
	fi
	return 1
}

# GALERA_READY
#
# Tests that the Galera provider is ready.
galera_ready()
{
	local s
	s=$(_process_sql --skip-column-names -e "select VARIABLE_VALUE from information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='WSREP_READY'")
	if [ "$s" = "ON" ]; then
		return 0
	fi
	return 1
}

# REPLICATION
#
# Tests the replication has the required set of functions:
# --replication_all -> Checks all replication sources
# --replication_name=n -> sets the multisource connection name tested
# --replication_io -> IO thread is running
# --replication_sql -> SQL thread is running
# --replication_seconds_behind_master=n -> less than or equal this seconds of delay
# --replication_sql_remaining_delay=n -> less than or equal this seconds of remaining delay
#  (ref: https://mariadb.com/kb/en/delayed-replication/)
replication()
{
	# SHOW REPLICA available 10.5+
	# https://github.com/koalaman/shellcheck/issues/2383
	# shellcheck disable=SC2016,SC2026
	_process_sql -e "SHOW ${repl['all']:+all} REPLICA${repl['all']:+S} ${repl['name']:+'${repl['name']}'} STATUS\G" | \
		{
		# required for trim of leading space.
		shopt -s extglob
		# Row header
		read -t 5 -r
		# read timeout
		[ $? -gt 128 ] && return 1
		while IFS=":" read -t 1 -r n v; do
			# Trim leading space
			n=${n##+([[:space:]])}
			# Leading space on all values by the \G format needs to be trimmed.
			v=${v:1}
			case "$n" in
				Slave_IO_Running)
					if [ -n "${repl['io']}" ] && [ "$v" = 'No' ]; then
						return 1
					fi
					;;
				Slave_SQL_Running)
					if [ -n "${repl['sql']}" ] && [ "$v" = 'No' ]; then
						return 1
					fi
					;;
				Seconds_Behind_Master)
					# A NULL value is the IO thread not running:
					if [ -n "${repl['seconds_behind_master']}" ] &&
						{ [ "$v" = NULL ] ||
							(( "${repl['seconds_behind_master']}" < "$v" )); }; then
						return 1
					fi
					;;
				SQL_Remaining_Delay)
					# Unlike Seconds_Behind_Master, sql_remaining_delay will hit NULL
					# once replication is caught up - https://mariadb.com/kb/en/delayed-replication/
					if [ -n "${repl['sql_remaining_delay']}" ] &&
						[ "$v" != NULL ] &&
						(( "${repl['sql_remaining_delay']}" < "$v" )); then
						return 1
					fi
					;;
			esac
		done
		# read timeout
		[ $? -gt 128 ] && return 1
		return 0
       }
       # reachable in command not found(?)
       # shellcheck disable=SC2317
       return $?
}

# mariadbupgrade
#
# Test the lock on the file $datadir/mysql_upgrade_info
# https://jira.mariadb.org/browse/MDEV-27068
mariadbupgrade()
{
	local f="$datadir/mysql_upgrade_info"
	if [ -r "$f" ]; then
		flock --exclusive --nonblock -n 9 9<"$f"
		return $?
	fi
	return 0
}


# MAIN

if [ $# -eq 0 ]; then
	echo "At least one argument required" >&2
	exit 1
fi

#ENDOFSUBSTITUTIONS
# Marks the end of mysql -> mariadb name changes in 10.6+
# Global variables used by tests
declare -A repl
declare -A def
nodefaults=
datadir=/var/lib/mysql
if [ -f $datadir/.my-healthcheck.cnf ]; then
	def['extra_file']=$datadir/.my-healthcheck.cnf
fi

_repl_param_check()
{
	case "$1" in
		seconds_behind_master) ;&
		sql_remaining_delay)
			if [ -z "${repl['io']}" ]; then
				repl['io']=1
				echo "Forcing --replication_io=1, $1 requires IO thread to be running" >&2
			fi
			;;
		all)
			if [ -n "${repl['name']}" ]; then
				unset 'repl[name]'
				echo "Option --replication_all incompatible with specified source --replication_name, clearing replication_name" >&2
			fi
			;;
		name)
			if [ -n "${repl['all']}" ]; then
				unset 'repl[all]'
				echo "Option --replication_name incompatible with --replication_all, clearing replication_all" >&2
			fi
			;;
	esac
}

_test_exists() {
    declare -F "$1" > /dev/null
    return $?
}

while [ $# -gt 0 ]; do
	case "$1" in
		--su=*)
			u="${1#*=}"
			shift
			exec gosu "${u}" "${BASH_SOURCE[0]}" "$@"
			;;
		--su)
			shift
			u=$1
			shift
			exec gosu "$u" "${BASH_SOURCE[0]}" "$@"
			;;
		--su-mysql)
			shift
			exec gosu mysql "${BASH_SOURCE[0]}" "$@"
			;;
		--replication_*=*)
			# Change the n to what is between _ and = and make lower case
			n=${1#*_}
			n=${n%%=*}
			n=${n,,*}
			# v is after the =
			v=${1#*=}
			repl[$n]=$v
			_repl_param_check "$n"
			;;
		--replication_*)
			# Without =, look for a non --option next as the value,
			# otherwise treat it as an "enable", just equate to 1.
			# Clearing option is possible with "--replication_X="
			n=${1#*_}
			n=${n,,*}
			if [ "${2:0:2}" == '--' ]; then
				repl[$n]=1
			else
				repl[$n]=$2
				shift
			fi
			_repl_param_check "$n"
			;;
		--datadir=*)
			datadir=${1#*=}
			;;
		--datadir)
			shift
			datadir=${1}
			;;
		--no-defaults)
			def=()
			nodefaults=1
			;;
		--defaults-file=*|--defaults-extra-file=*|--defaults-group-suffix=*)
			n=${1:11} # length --defaults-
			n=${n%%=*}
			n=${n//-/_}
			# v is after the =
			v=${1#*=}
			def[$n]=$v
			nodefaults=
			;;
		--defaults-file|--defaults-extra-file|--defaults-group-suffix)
			n=${1:11} # length --defaults-
			n=${n//-/_}
			if [ "${2:0:2}" == '--' ]; then
				def[$n]=""
			else
				def[$n]=$2
				shift
			fi
			nodefaults=
			;;
		--*)
			test=${1#--}
			;;
		*)
			echo "Unknown healthcheck option $1" >&2
			exit 1
	esac
	if [ -n "$test" ]; then
		if ! _test_exists "$test" ; then
			echo "healthcheck unknown option or test '$test'" >&2
			exit 1
		elif ! "$test"; then
			echo "healthcheck $test failed" >&2
			exit 1
		fi
		test=
	fi
	shift
done
