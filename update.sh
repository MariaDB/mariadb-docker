#!/usr/bin/env bash
set -Eeuo pipefail
#
# Usage ./update.sh [version(multiple)...]
#

defaultSuite='focal'
declare -A suites=(
	[10.2]='bionic'
)
declare -A dpkgArchToBashbrew=(
	[amd64]='amd64'
	[armel]='arm32v5'
	[armhf]='arm32v7'
	[arm64]='arm64v8'
	[i386]='i386'
	[ppc64el]='ppc64le'
	[s390x]='s390x'
)

getRemoteVersion() {
	local version="$1"; shift # 10.4
	local suite="$1"; shift # focal
	local dpkgArch="$1"; shift # arm64

	curl -fsSL "https://ftp.osuosl.org/pub/mariadb/repo/$version/ubuntu/dists/$suite/main/binary-$dpkgArch/Packages" 2>/dev/null  \
		| tac|tac \
		| awk -F ': ' '$1 == "Package" { pkg = $2; next } $1 == "Version" && pkg == "mariadb-server-'"$version"'" { print $2; exit }' || true
}

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	GLOBIGNORE=".*:tests"
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

for version in "${versions[@]}"; do
	if [ "$version" == 10.8 ]; then
		version=10.8.0
	fi
	if [ ! -d "$version" ]; then
		# assume full version and trim this to major version
		ExpectedFullVersion=$version
		version=${version%.[[:digit:]]*}
	else
		ExpectedFullVersion=
	fi
	suite="${suites[$version]:-$defaultSuite}"
	fullVersion="$(getRemoteVersion "$version" "$suite" 'amd64')"
	if [ -z "$fullVersion" ]; then
		echo >&2 "warning: cannot find $version in $suite"
		fullVersion=1:$version+maria~$suite
		echo >&2 "warning: assuming full version=$fullVersion"
	fi

	mariaVersion="${fullVersion##*:}"
	mariaVersion="${mariaVersion%%[-+~]*}"

	if [ -n "$ExpectedFullVersion" ] && [ "$ExpectedFullVersion" != "$mariaVersion" ]; then
		echo >&2 "warning: Version $ExpectedFullVersion is not the latest on the mirror, $mariaVersion is (for suite=$suite)"
		mariaVersion="$ExpectedFullVersion"
		fullVersion="1:${mariaVersion}+maria~${suite}"
		echo >&2 "warning: continuing with $fullVersion"
	fi

	# "Alpha", "Beta", "Gamma", "RC", "Stable", etc.
	releaseStatus="$(
		wget -qO- 'https://downloads.mariadb.org/mariadb/+releases/' \
			| xargs -d '\n' \
			| grep -oP '<tr>.+?</tr>' \
			| grep -P '>\Q'"$mariaVersion"'\E<' \
			| grep -oP '<td>[^0-9][^<]*</td>' \
			| sed -r 's!^.*<td>([^0-9][^<]*)</td>.*$!\1!' || echo Alpha
	)"
	case "$releaseStatus" in
		Alpha | Beta | Gamma | RC | Stable ) ;; # sanity check
		*) echo >&2 "error: unexpected 'release status' value for $mariaVersion: $releaseStatus"; ;;
	esac

	echo "$version: $mariaVersion ($releaseStatus)"

	arches=
	sortedArches="$(echo "${!dpkgArchToBashbrew[@]}" | xargs -n1 | sort | xargs)"
	for arch in $sortedArches; do
		if ver="$(getRemoteVersion "$version" "$suite" "$arch")" && [ -n "$ver" ]; then
			arches="$arches ${dpkgArchToBashbrew[$arch]}"
		fi
	done
	if [ -z "$arches" ]; then
		# assume default
		arches=" amd64 arm64v8 ppc64le s390x"
	fi

	cp Dockerfile.template "$version/Dockerfile"

	backup='mariadb-backup'
	# shellcheck disable=SC2072
	if [[ "$version" < "10.3" ]]; then
		# 10.2 has mariadb major version in the package name
		backup="$backup-$version"
	fi

	cp docker-entrypoint.sh healthcheck.sh "$version/"
	sed -i \
		-e 's!%%MARIADB_VERSION%%!'"$fullVersion"'!g' \
		-e 's!%%MARIADB_VERSION_BASIC%%!'"$mariaVersion"'!g' \
		-e 's!%%MARIADB_MAJOR%%!'"$version"'!g' \
		-e 's!%%MARIADB_RELEASE_STATUS%%!'"$releaseStatus"'!g' \
		-e 's!%%SUITE%%!'"$suite"'!g' \
		-e 's!%%BACKUP_PACKAGE%%!'"$backup"'!g' \
		-e 's!%%ARCHES%%!'"$arches"'!g' \
		"$version/Dockerfile"

	if [ "$suite" = bionic ]
	then
		sed -i 's/libjemalloc2/libjemalloc1/' "$version/Dockerfile"
	fi

	case "$version" in
		10.2 | 10.3 | 10.4) ;;
		*) sed -i '/backwards compat/d' "$version/Dockerfile" ;;
	esac
	# Start using the new executable names
	case "$version" in
		10.2 | 10.3 | 10.4 | 10.5) ;;
		*)
			sed -i -e '/^CMD/s/mysqld/mariadbd/' "$version/Dockerfile"
			sed -i -e 's/mysql_upgrade\([^_]\)/mariadb-upgrade\1/' \
			       -e 's/mysqldump/mariadb-dump/' \
			       -e 's/mysql_install_db/mariadb-install-db/' \
			       -e "0,/#ENDOFSUBSTITIONS/s/mysqld/mariadbd/" \
			       -e 's/mysql_tzinfo_to_sql/mariadb-tzinfo-to-sql/' \
			       "$version/docker-entrypoint.sh"
			sed -i -e '0,/#ENDOFSUBSTITIONS/s/\bmysql\b/mariadb/' "$version/healthcheck.sh"

	esac
done
