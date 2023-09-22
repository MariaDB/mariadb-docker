#!/bin/bash
set -eo pipefail

# logging functions
mysql_log() {
	local type="$1"; shift
	printf '%s [%s] [Entrypoint]: %s\n' "$(date --rfc-3339=seconds)" "$type" "$*"
}
mysql_note() {
	mysql_log Note "$@"
}
mysql_warn() {
	mysql_log Warn "$@" >&2
}
mysql_error() {
	mysql_log ERROR "$@" >&2
	exit 1
}

_main() {
    if [ "$1" = 'mariadbd' ]; then
        # simply start mariadb with column-store
        exec docker-entrypoint.sh "$@"
    elif [ "$1" = 'StorageManager' ]; then
        # Run StorageManage of column-store
        # storageManager's directroy :- /var/lib/columnstore/storagemanager
        print "$@"
    elif [ "$1" = 'brm' ]; then
        # Run brm
    fi
}

# Runs _main() function.
_main "$@"