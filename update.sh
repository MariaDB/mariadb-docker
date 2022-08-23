#!/usr/bin/env bash
set -Eeuo pipefail
#
# Usage ./update.sh [version(multiple)...]
#

defaultSuite='jammy'
declare -A suites=(
	[10.3]='focal'
	[10.4]='focal'
	[10.5]='focal'
	[10.6]='focal'
	[10.7]='focal'
)

declare -A suffix=(
	['focal']='ubu2004'
	['jammy']='ubu2204'
)

#declare -A dpkgArchToBashbrew=(
#	[amd64]='amd64'
#	[armel]='arm32v5'
#	[armhf]='arm32v7'
#	[arm64]='arm64v8'
#	[i386]='i386'
#	[ppc64el]='ppc64le'
#	[s390x]='s390x'
#)

update_version()
{
	echo "$version: $mariaVersion ($releaseStatus)"

	suite="${suites[$version]:-$defaultSuite}"
	fullVersion=1:${mariaVersion}+maria~${suffix[${suite}]}

	if [[ $version = 10.[234] ]]; then
		arches=" amd64 arm64v8 ppc64le"
	else
		arches=" amd64 arm64v8 ppc64le s390x"
	fi

	cp Dockerfile.template "$version/Dockerfile"

	cp docker-entrypoint.sh healthcheck.sh "$version/"
	chmod a+x "$version"/healthcheck.sh
	sed -i \
		-e 's!%%MARIADB_VERSION%%!'"$fullVersion"'!g' \
		-e 's!%%MARIADB_VERSION_BASIC%%!'"$mariaVersion"'!g' \
		-e 's!%%MARIADB_MAJOR%%!'"$version"'!g' \
		-e 's!%%MARIADB_RELEASE_STATUS%%!'"$releaseStatus"'!g' \
		-e 's!%%SUITE%%!'"$suite"'!g' \
		-e 's!%%ARCHES%%!'"$arches"'!g' \
		"$version/Dockerfile"

	# Start using the new executable names
	case "$version" in
		10.3 | 10.4) ;; # nothing to see/do here
		10.5)
			sed -i '/backwards compat/d' "$version/Dockerfile"
			;;
		10.9 | 10.10)
			# quoted $ intentional
			# shellcheck disable=SC2016
			sed -i -e '/^ARG MARIADB_MAJOR/d' \
				-e '/^ENV MARIADB_MAJOR/d' \
				-e 's/-\$MARIADB_MAJOR//' \
				"$version/Dockerfile"
			;&
		*)
			sed -i -e '/^CMD/s/mysqld/mariadbd/' \
			       -e '/backwards compat/d' "$version/Dockerfile"
			sed -i -e 's/mysql_upgrade\([^_]\)/mariadb-upgrade\1/' \
			       -e 's/mysqldump/mariadb-dump/' \
			       -e 's/mysqladmin/mariadb-admin/' \
			       -e 's/\bmysql --protocol\b/mariadb --protocol/' \
			       -e 's/mysql_install_db/mariadb-install-db/' \
			       -e "0,/#ENDOFSUBSTITUTIONS/s/mysqld/mariadbd/" \
			       -e 's/mysql_tzinfo_to_sql/mariadb-tzinfo-to-sql/' \
			       "$version/docker-entrypoint.sh"
			sed -i -e '0,/#ENDOFSUBSTITUTIONS/s/\bmysql\b/mariadb/' "$version/healthcheck.sh"
			;;
		esac
}

mariaversion()
{
	mariaVersion=$( curl -fsSL https://downloads.mariadb.org/rest-api/mariadb/"${version}" \
	       | jq 'first(..|select(.release_id)) | .release_id' )
	mariaVersion=${mariaVersion//\"}
}

all()
{
	curl -fsSL https://downloads.mariadb.org/rest-api/mariadb/ \
		| jq '.major_releases[] | [ .release_id ], [ .release_status ]  | @tsv ' \
		| while read -r version
	do
		version=${version//\"}
		if [ ! -d "$version" ]; then
			echo >&2 "warning: no rule for $version"
			continue
		fi
		mariaversion

		read -r releaseStatus
		releaseStatus=${releaseStatus//\"}
	
		case "$releaseStatus" in
			Alpha | Beta | Gamma | RC | Stable ) ;; # sanity check
		        "Old Stable" )
				releaseStatus=Stable
			       	;; # insanity check
			*) echo >&2 "error: unexpected 'release status' value for $mariaVersion: $releaseStatus"; ;;
		esac

		update_version
	done
}

development_version=10.10

in_development()
{
	releaseStatus=Alpha
	version=$development_version
	mariaVersion=${development_version}.0
	[ -d "$development_version" ] && update_version
}


if [ $# -eq 0 ]; then
	all
	in_development
	exit 0
fi

versions=( "$@" )

for version in "${versions[@]}"; do
	if [ "$version" == $development_version ]; then
		in_development
		continue
	fi
	if [ ! -d "$version" ]; then
		mariaVersion=$version
		version=${version%.[[:digit:]]*}
	else
		mariaversion
	fi
	releaseStatus=$(curl -fsSL https://downloads.mariadb.org/rest-api/mariadb/ \
		| jq ".major_releases[] | select(.release_id == \"$version\") | .release_status")
	releaseStatus=${releaseStatus//\"}
	
	update_version
done
