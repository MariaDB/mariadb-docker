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
    if [ "$1" = 'StorageManager' ]; then
        # Run StorageManage of column-store
        # storageManager's directroy :- /var/lib/columnstore/storagemanager
        echo "$@"
    elif [ "$1" = 'brm' ]; then
        # Run brm
        echo "$@"
    else
        # if [ "$1" = 'mariadbd' ] or No argument then by default: 
        # simply start mariadb with column-store
        exec docker-entrypoint.sh "$@"
    fi
}

# Runs _main() function.
_main "$@"