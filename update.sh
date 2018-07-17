#!/bin/bash
set -eo pipefail

defaultSuite='bionic'
declare -A suites=(
	[5.5]='trusty'
	[10.0]='xenial'
)
defaultXtrabackup='mariadb-backup'
declare -A xtrabackups=(
	[5.5]='percona-xtrabackup'
	[10.0]='percona-xtrabackup'
)
declare -A dpkArchToBashbrew=(
	[amd64]='amd64'
	[armel]='arm32v5'
	[armhf]='arm32v7'
	[arm64]='arm64v8'
	[i386]='i386'
	[ppc64el]='ppc64le'
	[s390x]='s390x'
)

getRemoteVersion() {
	local version="$1"; shift # 10.3
	local suite="$1"; shift # bionic
	local dpkgArch="$1" shift # arm64

	echo "$(
		curl -fsSL "http://ftp.osuosl.org/pub/mariadb/repo/$version/ubuntu/dists/$suite/main/binary-$dpkgArch/Packages" 2>/dev/null  \
			| tac|tac \
			| awk -F ': ' '$1 == "Package" { pkg = $2; next } $1 == "Version" && pkg == "mariadb-server" { print $2; exit }'
	)"
}

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

travisEnv=
for version in "${versions[@]}"; do
	suite="${suites[$version]:-$defaultSuite}"
	fullVersion="$(getRemoteVersion "$version" "$suite" 'amd64')"
	if [ -z "$fullVersion" ]; then
		echo >&2 "warning: cannot find $version in $suite"
		continue
	fi

	arches=
	for arch in "${!dpkArchToBashbrew[@]}"; do
		if ver="$(getRemoteVersion "$version" "$suite" "$arch")" && [ -n "$ver" ]; then
			arches="$arches ${dpkArchToBashbrew[$arch]}"
		fi
	done

	backup="${xtrabackups[$version]:-$defaultXtrabackup}"

	cp Dockerfile.template "$version/Dockerfile"
	if [ "$backup" == 'percona-xtrabackup' ]; then
		gawk -i inplace '
		{ print }
		/%%XTRABACKUP%%/ && c == 0 { c = 1; system("cat Dockerfile-percona-block") }
		' "$version/Dockerfile"
	elif [ "$backup" == 'mariadb-backup' ] && [[ "$version" < 10.3 ]]; then
		# 10.1 and 10.2 have mariadb major version in the package name
		backup="$backup-$version"
	fi

	(
		set -x
		cp docker-entrypoint.sh "$version/"
		sed -i \
			-e 's!%%MARIADB_VERSION%%!'"$fullVersion"'!g' \
			-e 's!%%MARIADB_MAJOR%%!'"$version"'!g' \
			-e 's!%%SUITE%%!'"$suite"'!g' \
			-e 's!%%XTRABACKUP%%!'"$backup"'!g' \
			-e 's!%%ARCHES%%!'"$arches"'!g' \
			"$version/Dockerfile"
	)
	
	travisEnv='\n  - VERSION='"$version$travisEnv"
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
