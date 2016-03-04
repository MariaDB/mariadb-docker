#!/bin/bash
set -eo pipefail

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

travisEnv=
for version in "${versions[@]}"; do
	suite="${suites[$version]:-$defaultSuite}"
	fullVersion="$(curl -sSL "http://ftp.osuosl.org/pub/mariadb/repo/$version/debian/dists/$suite/main/binary-amd64/Packages" |tac|tac| grep -m1 -A10 "^Package: mariadb-server\$" | grep -m1 '^Version: ' | cut -d' ' -f2)"
	if [ -z "$fullVersion" ]; then
		echo >&2 "warning: cannot find $version in $suite"
		continue
	fi
	(
		set -x
		cp docker-entrypoint.sh "$version/"
		sed '
			s/%%SUITE%%/'"$suite"'/g;
			s/%%MARIADB_MAJOR%%/'"$version"'/g;
			s/%%MARIADB_VERSION%%/'"$fullVersion"'/g;
		' Dockerfile.template > "$version/Dockerfile"
	)
	
	travisEnv='\n  - VERSION='"$version$travisEnv"
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
