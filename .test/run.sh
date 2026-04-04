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
	  -h, --help       Show this help message and exit
	  -l, --list       List all available tests and exit
	  -v, --verbose    Show full trace output for tests
	      --xml [path] Emit basic JUnit style XML report (default: .test/mtr-report.xml)

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
xml_enabled=0
xml_output=""
default_xml_output=".test/mtr-report.xml"
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
		--xml)
			xml_enabled=1
			if [ $# -gt 1 ] && [ -n "$image" ] && [[ "$2" != -* ]]; then
				xml_output="$2"
				shift
			fi
			;;
		--xml=*)
			xml_enabled=1
			xml_output="${1#--xml=}"
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

if [ "$xml_enabled" -eq 1 ] && [ -z "$xml_output" ]; then
	xml_output="$default_xml_output"
fi

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

passed=0
failed=0

test_logfile=$(mktemp)
xml_cases_file=""

xml_escape() {
	local text="${1-}"
	text=${text//&/&amp;}
	text=${text//</&lt;}
	text=${text//>/&gt;}
	text=${text//\"/&quot;}
	text=${text//\'/'&apos;'}
	printf '%s' "$text"
}

xml_add_testcase() {
	local name="$1"
	local status="$2"
	local failure_text="${3-}"
	local elapsed="${4-0.000}"
	local classname="main"
	local escaped_name escaped_classname escaped_combinations

	[ "$xml_enabled" -ne 1 ] && return

	escaped_name="$(xml_escape "$name")"
	escaped_classname="$(xml_escape "$classname")"
	escaped_combinations="$(xml_escape "$image")"

	if [ "$status" = "MTR_RES_PASSED" ]; then
		printf '\t\t<testcase classname="%s" name="%s" status="%s" time="%s" combinations="%s" />\n' \
			"$escaped_classname" "$escaped_name" "$status" "$elapsed" "$escaped_combinations" >> "$xml_cases_file"
	else
		printf '\t\t<testcase classname="%s" name="%s" status="%s" time="%s" combinations="%s">\n' \
			"$escaped_classname" "$escaped_name" "$status" "$elapsed" "$escaped_combinations" >> "$xml_cases_file"
		printf '\t\t\t<failure>%s</failure>\n' "$(xml_escape "$failure_text")" >> "$xml_cases_file"
		printf '\t\t</testcase>\n' >> "$xml_cases_file"
	fi
}

write_xml_report() {
	if [ "$xml_enabled" -ne 1 ]; then
		return
	fi

	local tests total_time timestamp
	local escaped_suite_name
	local xml_dir

	tests=$((passed + failed))
	total_time=$(awk -v s="$xml_suite_start" -v e="${EPOCHREALTIME:-$SECONDS}" 'BEGIN{printf "%.3f", e - s}')
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	escaped_suite_name="$(xml_escape "main")"
	xml_dir="$(dirname "$xml_output")"

	mkdir -p "$xml_dir"

	{
		printf '<?xml version="1.0" encoding="UTF-8"?>\n'
		printf '<testsuites disabled="0" errors="" failures="%s" name="" tests="%s" time="%s">\n' "$failed" "$tests" "$total_time"
		printf '\t<testsuite disabled="" errors="" failures="%s" hostname="" id="0" name="%s" package="" skipped="" tests="%s" time="%s" timestamp="%s">\n' "$failed" "$escaped_suite_name" "$tests" "$total_time" "$timestamp"
		if [ -n "$xml_cases_file" ] && [ -s "$xml_cases_file" ]; then
			cat "$xml_cases_file"
		fi
		printf '\t</testsuite>\n'
		printf '</testsuites>\n'
	} > "$xml_output"
}

cleanup() {
	local exit_code=$?

	set +e
	write_xml_report
	rm -f "$test_logfile"
	if [ -n "$xml_cases_file" ]; then
		rm -f "$xml_cases_file"
	fi
	killoff
	trap - EXIT
	exit "$exit_code"
}

xml_suite_start=0
if [ "$xml_enabled" -eq 1 ]; then
	xml_cases_file=$(mktemp)
	xml_suite_start=${EPOCHREALTIME:-$SECONDS}
fi

trap cleanup EXIT

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

run_test() {
	local name="$1"
	local failure_text=""
	local test_start elapsed

	# Used in sourced lib.sh functions (killoff, mariadb, etc.)
	# shellcheck disable=SC2034
	cname=""
	# shellcheck disable=SC2034
	cid=""
	: > "$test_logfile"
	test_start=${EPOCHREALTIME:-$SECONDS}
	if [ "$verbose" -eq 1 ]; then
		echo ""
		echo "=> Running: $name"
		echo ""
		if ( set -x; "test_$name" ) 2>&1 | tee "$test_logfile"; then
			elapsed=$(awk -v s="$test_start" -v e="${EPOCHREALTIME:-$SECONDS}" 'BEGIN{printf "%.3f", e - s}')
			echo "PASSED: $name"
			(( passed++ )) || :
			xml_add_testcase "$name" "MTR_RES_PASSED" "" "$elapsed"
		else
			elapsed=$(awk -v s="$test_start" -v e="${EPOCHREALTIME:-$SECONDS}" 'BEGIN{printf "%.3f", e - s}')
			failure_text="$(cat "$test_logfile")"
			echo "FAILED: $name"
			(( failed++ )) || :
			xml_add_testcase "$name" "MTR_RES_FAILED" "$failure_text" "$elapsed"
		fi
		echo
	else
		printf '=> %-45s ' "$name"
		if ( set -x; "test_$name" ) > "$test_logfile" 2>&1; then
			elapsed=$(awk -v s="$test_start" -v e="${EPOCHREALTIME:-$SECONDS}" 'BEGIN{printf "%.3f", e - s}')
			echo "PASSED"
			(( passed++ )) || :
			xml_add_testcase "$name" "MTR_RES_PASSED" "" "$elapsed"
		else
			elapsed=$(awk -v s="$test_start" -v e="${EPOCHREALTIME:-$SECONDS}" 'BEGIN{printf "%.3f", e - s}')
			failure_text="$(cat "$test_logfile")"
			echo "FAILED"
			echo " test output "
			cat "$test_logfile"
			echo " end output ─"
			(( failed++ )) || :
			xml_add_testcase "$name" "MTR_RES_FAILED" "$failure_text" "$elapsed"
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
