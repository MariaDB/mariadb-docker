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

check_existence() {
    for n in a b c;
    do
        echo $n
    done
}

validate_args() {
    storage_manager_args[0]=service
    storage_manager_args[1]=object_size 
    storage_manager_args[2]=metadata_path
    storage_manager_args[3]=max_concurrent_downloads
    storage_manager_args[4]=max_concurrent_uploads
    storage_manager_args[5]=common_prefix_depth
    storage_manager_args[6]=region
    storage_manager_args[7]=bucket
    storage_manager_args[8]=endpoint
    storage_manager_args[9]=aws_access_key_id
    storage_manager_args[10]=aws_secret_access_key
    storage_manager_args[11]=iam_role_name
    storage_manager_args[12]=sts_region
    storage_manager_args[13]=sts_endpoint
    storage_manager_args[14]=ec2_iam_mode
    storage_manager_args[15]=use_http
    storage_manager_args[16]=ssl_verify
    storage_manager_args[17]=libs3_debug
    storage_manager_args[18]=path
    storage_manager_args[19]=fake_latency
    storage_manager_args[20]=max_latency
    storage_manager_args[21]=cache_size
    storage_manager_args[22]=cache_path

    # ************Code Here ************
    # Split each arg by `=`. And check whether arg exist in storage_manager_args or not.
    # If Not then print an error/warning message to the user but don't fail.

    # If everything is alright then update the default values if arguments ware provided by user relevant to the fields.
}

get_storage_manager_default_values() {
    # For [ObjectStorage]
    service='LocalStorage'
    object_size='5M'
    metadata_path='@ENGINE_DATADIR@/storagemanager/metadata'
    journal_path='@ENGINE_DATADIR@/storagemanager/journal'
    max_concurrent_downloads=21
    max_concurrent_uploads=21
    common_prefix_depth=3

    # For [S3]
    region=''
    bucket=''
    endpoint=''
    prefix='cs/'
    aws_access_key_id=''
    aws_secret_access_key=''
    iam_role_name=
    sts_region=
    sts_endpoint=
    ec2_iam_mode=
    use_http=
    ssl_verify=
    libs3_debug=

    # The LocalStorage section configures the 'local storage' module
    # if specified by ObjectStorage/service.
    # [LocalStorage]

    # path specifies where the module should store object data.
    path='@ENGINE_DATADIR@/storagemanager/fake-cloud'
    fake_latency=
    max_latency=50000

    # [Cache]
    cache_size='2g'
    cache_path='@ENGINE_DATADIR@/storagemanager/cache'

}

_main() {
    if [ "$1" = 'StorageManager' ]; then
        # Run StorageManage of column-store
        # storageManager's directroy :- /var/lib/columnstore/storagemanager
        shift
        validate_args "$@"
        get_storage_manager_default_values

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