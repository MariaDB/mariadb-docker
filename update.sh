#!/bin/bash
set -e

declare -A suites=(
	[5.5]='wheezy'
)
defaultSuite='jessie'

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )


for version in "${versions[@]}"; do
	suite="${suites[$version]:-$defaultSuite}"
	fullVersion="$(curl -sSL "http://ftp.osuosl.org/pub/mariadb/repo/$version/debian/dists/$suite/main/binary-amd64/Packages" |tac|tac| grep -m1 -A10 "^Package: mariadb-server\$" | grep -m1 '^Version: ' | cut -d' ' -f2)"
	if [ -z "$fullVersion" ]; then
		echo >&2 "warning: cannot find $version in $suite"
		continue
	fi
	(
		set -x
		cp docker-entrypoint.sh Dockerfile.template "$version/"
		mv "$version/Dockerfile.template" "$version/Dockerfile"
		sed -i '
			s/%%SUITE%%/'"$suite"'/g;
			s/%%MARIADB_MAJOR%%/'"$version"'/g;
			s/%%MARIADB_VERSION%%/'"$fullVersion"'/g;
		' "$version/Dockerfile"
	)
done
