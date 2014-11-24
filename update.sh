#!/bin/bash
set -e

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )


for version in "${versions[@]}"; do
	fullVersion="$(curl -sSL "http://ftp.osuosl.org/pub/mariadb/repo/$version/debian/dists/wheezy/main/binary-amd64/Packages" | grep -m1 -A10 "^Package: mariadb-server\$" | grep -m1 '^Version: ' | cut -d' ' -f2)"
	(
		set -x
		cp docker-entrypoint.sh Dockerfile.template "$version/"
		mv "$version/Dockerfile.template" "$version/Dockerfile"
		sed -i 's/%%MARIADB_MAJOR%%/'$version'/g; s/%%MARIADB_VERSION%%/'$fullVersion'/g' "$version/Dockerfile"
	)
done
