#!/bin/bash
set -eo pipefail

declare -A suites=(
	[5.5]='wheezy'
	[10.0]='jessie'
	[10.1]='jessie'
)
defaultSuite='stretch'

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

travisEnv=
for version in "${versions[@]}"; do
	suite="${suites[$version]:-$defaultSuite}"
	fullVersion="$(
		curl -fsSL "http://ftp.osuosl.org/pub/mariadb/repo/$version/debian/dists/$suite/main/binary-amd64/Packages" \
			| tac|tac \
			| awk -F ': ' '$1 == "Package" { pkg = $2; next } $1 == "Version" && pkg == "mariadb-server" { print $2; exit }'
	)"
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
