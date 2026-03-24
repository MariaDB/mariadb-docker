#!/bin/bash
# Tests for memory allocators (jemalloc, tcmalloc)
# Sourced by run.sh — do not execute directly

test_jemalloc() {
	case "$architecture" in
		amd64)   debarch=x86_64 ;;
		arm64)   debarch=aarch64 ;;
		ppc64le) debarch=powerpc64le ;;
		s390x|i386|*) debarch=$architecture ;;
	esac

	if [ -n "$debarch" ]; then
		echo -e "Test: jemalloc preload\n"
		runandwait -e LD_PRELOAD="/usr/lib/$debarch-linux-gnu/libjemalloc.so.1 /usr/lib/$debarch-linux-gnu/libjemalloc.so.2 /usr/lib64/libjemalloc.so.2" -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
		docker exec -i --user mysql "$cid" /bin/grep 'jemalloc' /proc/1/maps || die "expected to preload jemalloc"
		killoff
	else
		echo -e "Test: jemalloc skipped - unknown arch '$architecture'\n"
	fi
}

test_tcmalloc() {
	case "$architecture" in
		amd64)   debarch=x86_64 ;;
		arm64)   debarch=aarch64 ;;
		ppc64le) debarch=powerpc64le ;;
		s390x|i386|*) debarch=$architecture ;;
	esac

	if [ -n "$debarch" ]; then
		echo -e "Test: tcmalloc preload\n"
		runandwait -e LD_PRELOAD="/usr/lib/$debarch-linux-gnu/libtcmalloc_minimal.so.4 /usr/lib64/libtcmalloc_minimal.so.4" -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 "${image}"
		docker exec -i --user mysql "$cid" /bin/grep 'tcmalloc' /proc/1/maps || die "expected to preload tcmalloc"
		killoff
	else
		echo -e "Test: tcmalloc skipped - unknown arch '$architecture'\n"
	fi
}
