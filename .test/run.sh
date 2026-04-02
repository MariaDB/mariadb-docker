#!/bin/bash

# MariaDB Docker image test runner
#
# Tests are defined as test_* functions in tests/*.sh files.
# Shared utilities live in lib.sh.

set -eo pipefail

dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

usage() {
	cat <<-EOF
	Usage: $0 [OPTIONS] <image> [test_name...]

	Run MariaDB Docker image tests.

	Arguments:
	  image        Container image hash or tag to test
	  test_name    Run one or more specific tests (without the test_ prefix)

	Options:
	  -h, --help      Show this help message and exit
	  -l, --list      List all available tests and exit
	  -v, --verbose   Show full trace output for tests

	Examples:
	  $0 mariadb:latest                        Run all tests
	  $0 -v mariadb:latest                     Run all tests with verbose output
	  $0 mariadb:latest replication            Run only the 'replication' test
	  $0 mariadb:latest replication binlog     Run only the named tests
	  $0 --list                                List available tests
	EOF
}

# Parse options
verbose=0
list_tests=0
image=""
test_names=()

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		-l|--list)
			list_tests=1
			;;
		-v|--verbose)
			verbose=1
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			if [ -z "$image" ]; then
				image="$1"
			else
				test_names+=("$1")
			fi
			;;
	esac
	shift
done

# Build ordered test list 
# Defines the canonical execution order. Each entry is a test_ function name
# (without the prefix). Add new tests by appending to this array.

TEST_ORDER=(
	required_password
	mysql_allow_empty_password_is_empty
	mysql_allow_empty_password_is_clean
	mysql_root_password_is_set
	mysql_random_password_is_complex
	mysql_random_password_is_different
	mysql_root_host_sets_host
	mysql_root_host_localhost
	complex_passwords
	mysql_initdb_skip_tzinfo_empty
	mysql_initdb_skip_tzinfo_no_empty
	secrets_via_file
	docker_entrypoint_initdb
	prefer_mariadb_names
	mariadb_allow_empty_root_password_empty
	mariadb_allow_empty_root_password_not_empty
	mariadb_root_password_is_set
	mariadb_root_password_is_complex
	mariadb_root_password_is_different
	mariadb_root_host_sets_host
	mariadb_initdb_skip_tzinfo_empty
	mariadb_initdb_skip_tzinfo_not_empty
	jemalloc
	tcmalloc
	mariadbupgrade
	encryption
	binlog
	validate_master_env
	validate_replica_env
	replication
	replication_password_hash
	password_hash
	galera_mariadbbackup
	galera_sst_rsync
	backup_restore
	mariadb_user_host
)

if [ "$list_tests" -eq 1 ]; then
	echo "Available tests:"
	for t in "${TEST_ORDER[@]}"; do
		echo "  $t"
	done
	exit 0
fi

if [ -z "$image" ]; then
	echo "Error: <image> argument is required." >&2
	usage >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$dir/lib.sh"

# Ensure test fixtures are readable by the mysql user inside containers
chmod -R go+rX "$dir"/initdb.d "$dir"/encryption "$dir"/encryption_conf "$dir"/initenc "$dir"/tls 2>/dev/null || true

for f in "$dir"/tests/*.sh; do
	# shellcheck source=/dev/null
	source "$f"
done

# Detect image capabilities

# Used in sourced test files (e.g. tests/allocator.sh) and lib.sh
# shellcheck disable=SC2034
architecture=$(docker image inspect --format '{{.Architecture}}' "$image")

# Enable xtrace only in verbose mode
if [ "$verbose" -eq 1 ]; then
	set -x
fi

# Validate requested test exists

validate_test() {
	local name="$1"
	if ! declare -f "test_$name" > /dev/null 2>&1; then
		echo "Test '$name' not found. Use --list to see available tests." >&2
		exit 1
	fi
}

# Run a single test with status tracking

passed=0
failed=0

test_logfile=$(mktemp)
trap 'rm -f "$test_logfile"; killoff' EXIT

run_test() {
	local name="$1"

	# Used in sourced lib.sh functions (killoff, mariadb, etc.)
	# shellcheck disable=SC2034
	cname=""
	# shellcheck disable=SC2034
	cid=""
	if [ "$verbose" -eq 1 ]; then
		echo ""
		echo "=> Running: $name"
		echo ""
		if "test_$name"; then
			echo "PASSED: $name"
			(( passed++ )) || :
		else
			echo "FAILED: $name"
			(( failed++ )) || :
		fi
		echo
	else
		printf '=> %-45s ' "$name"
		if ( set -x; "test_$name" ) > "$test_logfile" 2>&1; then
			echo "PASSED"
			(( passed++ )) || :
		else
			echo "FAILED"
			echo " test output "
			cat "$test_logfile"
			echo " end output ─"
			(( failed++ )) || :
		fi
	fi
}

if [ ${#test_names[@]} -gt 0 ]; then
	for test_name in "${test_names[@]}"; do
		validate_test "$test_name"
		run_test "$test_name"
	done
else
	# Run all tests
	for t in "${TEST_ORDER[@]}"; do
		validate_test "$t"
		run_test "$t"
	done
fi

echo "══════════════════════════════════════════════════════════════"
echo " Results: $passed passed, $failed failed"
echo "══════════════════════════════════════════════════════════════"

if [ "$failed" -gt 0 ]; then
	exit 1
fi
