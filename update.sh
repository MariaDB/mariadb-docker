#!/usr/bin/env bash
set -Eeuo pipefail
#
# Usage ./update.sh [version(multiple)...]
#

defaultSuite='noble'
declare -A suites=(
	[10.4]='focal'
	[10.5]='focal'
	[10.6]='focal'
	[10.11]='jammy'
	[11.0]='jammy'
	[11.1]='jammy'
	[11.2]='jammy'
	[11.3]='jammy'
)

declare -A suffix=(
	['focal']='ubu2004'
	['jammy']='ubu2204'
	['noble']='ubu2404'
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

# For testing with https://downloads.dev.mariadb.org/rest-api
typeset -r DOWNLOADS_REST_API="https://downloads.mariadb.org/rest-api"

update_version()
{
	local dir=$version$ubi
	if [ ! -d "$dir" ]; then
		echo "Directory $dir missing"
		return
	fi
	echo "$version: $mariaVersion($ubi) ($releaseStatus)"

	if [ -z "$ubi" ]; then
		suite="${suites[$version]:-$defaultSuite}"
		fullVersion=1:${mariaVersion}+maria~${suffix[${suite}]}
	else
		suite=
		fullVersion=$mariaVersion
		cp docker.cnf "$dir"
		sed -e "s!%%MARIADB_VERSION%%!${version%-*}!" MariaDB-ubi.repo > "$dir"/MariaDB.repo
	fi

	if [[ $version = 10.[234]* ]]; then
		arches="amd64 arm64v8 ppc64le"
	else
		arches="amd64 arm64v8 ppc64le s390x"
	fi

	cp "Dockerfile${ubi}.template" "${dir}/Dockerfile"

	cp docker-entrypoint.sh healthcheck.sh "$dir/"
	chmod a+x "$dir"/healthcheck.sh
	sed -i \
		-e 's!%%MARIADB_VERSION%%!'"$fullVersion"'!g' \
		-e 's!%%MARIADB_VERSION_BASIC%%!'"$mariaVersion"'!g' \
		-e 's!%%MARIADB_MAJOR%%!'"${version%-ubi}"'!g' \
		-e 's!%%MARIADB_RELEASE_STATUS%%!'"$releaseStatus"'!g' \
		-e 's!%%MARIADB_SUPPORT_TYPE%%!'"$supportType"'!g' \
		-e 's!%%SUITE%%!'"$suite"'!g' \
		-e 's!%%ARCHES%%! '"$arches"'!g' \
		"$dir/Dockerfile"

	sed -i \
		-e 's!%%MARIADB_VERSION_BASIC%%!'"$mariaVersion"'!g' \
		"$dir/docker-entrypoint.sh"

	vmin=${version%-ubi}
	# Start using the new executable names
	case "$vmin" in
		10.4)
			sed -i -e '/--old-mode/d' \
				-e 's/REPLICATION REPLICA/REPLICATION SLAVE/' \
			       	-e 's/START REPLICA/START SLAVE/' \
				-e '/memory\.pressure/,+7d' \
				"$version/docker-entrypoint.sh"
			sed -i -e 's/ REPLICA\$/ SLAVE$/' "$dir"/healthcheck.sh
			sed -i -e 's/\/run/\/var\/run\//g' "$dir/Dockerfile"
			;; # almost nothing to see/do here
		10.5)
			sed -i -e '/--old-mode/d' \
				-e '/memory\.pressure/,+7d' "$dir/docker-entrypoint.sh"
			sed -i '/backwards compat/d' "$dir/Dockerfile"
			;;
		*)
			sed -i -e '/^CMD/s/mysqld/mariadbd/' \
				-e '/backwards compat/d' "$dir/Dockerfile"
			sed -i -e 's/mysql_upgrade\([^_]\)/mariadb-upgrade\1/' \
				-e 's/mysqldump/mariadb-dump/' \
				-e 's/mysqladmin/mariadb-admin/' \
				-e 's/\bmysql --protocol\b/mariadb --protocol/' \
				-e 's/mysql_install_db/mariadb-install-db/' \
				-e 's/mysql_tzinfo_to_sql/mariadb-tzinfo-to-sql/' \
				"$dir/docker-entrypoint.sh"
			if [ "$vmin" = 10.6 ]; then
				# my_print_defaults didn't recognise --mysqld until 10.11
				sed -i -e '0,/#ENDOFSUBSTITUTIONS/s/\([^-]\)mysqld/\1mariadbd/g' \
					"$dir/docker-entrypoint.sh"
			else
				sed -i -e '0,/#ENDOFSUBSTITUTIONS/s/\mysqld/mariadbd/g' \
					"$dir/docker-entrypoint.sh"
			fi
			sed -i -e '0,/#ENDOFSUBSTITUTIONS/s/\bmysql\b/mariadb/' "$dir/healthcheck.sh"
			if [[ ! "${vmin}" =~ 10.[678] ]]; then
				# quoted $ intentional
				# shellcheck disable=SC2016
				sed -i -e '/^ARG MARIADB_MAJOR/d' \
					-e '/^ENV MARIADB_MAJOR/d' \
					-e 's/-\$MARIADB_MAJOR//' \
					"$dir/Dockerfile"
			else
				sed -i -e '/memory\.pressure/,+7d' "$dir/docker-entrypoint.sh"
			fi
			if [[ $vmin =~ 11.[012345] ]]; then
				sed -i -e 's/mysql_upgrade_info/mariadb_upgrade_info/' \
					"$dir/docker-entrypoint.sh" "$dir/healthcheck.sh"
			fi
			if [[ $vmin =~ 11.[01] ]]; then
				sed -i -e 's/50-mysqld_safe.cnf/50-mariadb_safe.cnf/' "$dir/Dockerfile"
			fi
			;&
	esac

	if [ -z "$suite" ]; then
		base=ubi9
	else
		base=ubuntu:$suite
	fi
	# Add version to versions.json
	versionJson="$(jq -e \
		--arg milestone "${version}" --arg milestoneversion "${version}${ubi}" --arg version "$mariaVersion" --arg fullVersion "$fullVersion" --arg releaseStatus "$releaseStatus" --arg supportType "$supportType" --arg base "$base" --arg arches "${arches# }" \
		'.[$milestoneversion] = {"milestone": $milestone, "version": $version, "fullVersion": $fullVersion, "releaseStatus": $releaseStatus, "supportType": $supportType, "base": $base, "arches": $arches|split(" ")}' versions.json)"
	printf '%s\n' "$versionJson" > versions.json
}

update_version_array()
{
	c0=$(( $1 - 2 ))
	c1=$(( $1 - 1 ))
	version=${release[$c0]}
	if [ ! -d "$version" ]; then
		echo >&2 "warning: no rule for $version"
		return
	fi
	mariaversion

	releaseStatus=${release[$c1]}

	case "$releaseStatus" in
		Alpha | Beta | Gamma | RC | Stable ) ;; # sanity check
		*) echo >&2 "error: unexpected 'release status' value for $mariaVersion: $releaseStatus"; ;;
	esac

	supportType=$2

	update_version
	ubi=-ubi update_version
}

mariaversion()
{
	mariaVersion=$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/${version%-*}" \
		| jq -r 'first(.releases[]).release_id')
	mariaVersion=${mariaVersion//\"}
}

all()
{
	printf '%s\n' "{}" > versions.json

	readarray -O 0 -c 3 -C update_version_array -t release <<< "$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/" \
		| jq -r '.major_releases[] | [ .release_id ], [ .release_status ], [ .release_support_type ]  | @tsv')"
}

development_version=11.5

in_development()
{
	releaseStatus=Alpha
	supportType=Unknown
	version=$development_version
	mariaVersion=${development_version}.0
	update_version
}


if [ $# -eq 0 ]; then
	ubi=
	in_development
	ubi=-ubi in_development
	all
	exit 0
fi

versions=( "$@" )

for version in "${versions[@]}"; do
	if [ "${version#*-}" = "ubi" ]; then
		ubi=-ubi
		version=${version%-ubi}
	else
		ubi=
	fi

	if [ "${version%-*}" == $development_version ]; then
		in_development
		continue
	fi
	if [ ! -d "$version" ]; then
		version=${version%.[[:digit:]]*}
	else
		mariaversion
	fi
	readarray -t release <<< "$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/" \
		| jq -r --arg version "${version%-*}" '.major_releases[] | select(.release_id == $version) | [ .release_status ] , [ .release_support_type ] | @tsv')"
	releaseStatus=${release[0]}
	supportType=${release[1]}

	update_version
done
