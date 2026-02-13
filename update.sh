#!/usr/bin/env bash
set -Eeuo pipefail
#
# Usage ./update.sh [version(multiple)...]
#

development_version=main
development_version_real=12.3

defaultSuite='noble'
defaultSuiteUBI='ubi10-minimal'
declare -A suites=(
	[10.5]='focal'
	[10.6]='jammy'
	[10.11]='jammy'
	['10.6-ubi']='ubi9-minimal'
	['10.11-ubi']='ubi9-minimal'
	['11.4-ubi']='ubi9-minimal'
	['11.8-ubi']='ubi9-minimal'
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
		suite="${suites[$dir]:-$defaultSuiteUBI}"
		fullVersion=$mariaVersion
		if [[ $version = 10.* ]]; then
			sed -e '/character-set-collations/d' docker.cnf > "$dir/docker.cnf"
		else
			sed -e '/collation-server/d' docker.cnf > "$dir/docker.cnf"
			if [[ $version != 11.4 ]]; then
				sed -i -e '/character-set-collations/d' "$dir/docker.cnf"
				sed -i -e '/character-set/d' "$dir/docker.cnf"
			fi
		fi
		sed -e "s!%%MARIADB_VERSION%%!${version%-*}!" MariaDB-ubi.repo > "$dir"/MariaDB.repo
	fi

	if [[ $version = 10.[234]* ]]; then
		arches="amd64 arm64v8 ppc64le"
	else
		arches="amd64 arm64v8 ppc64le s390x"
	fi

	if [[ $suite = 'jammy' ]]; then
		tcmallocUbuntuPkgName="libtcmalloc-minimal4"
	else
		tcmallocUbuntuPkgName="libtcmalloc-minimal4t64"
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
		-e 's!%%TCMALLOC_UBUNTU_PKG_NAME%%!'"$tcmallocUbuntuPkgName"'!g' \
		-e 's!%%SUITE%%!'"$suite"'!g' \
		-e 's!%%ARCHES%%! '"$arches"'!g' \
		"$dir/Dockerfile"

	sed -i \
		-e 's!%%MARIADB_VERSION_BASIC%%!'"$mariaVersion"'!g' \
		"$dir/docker-entrypoint.sh"

	if [ "$suite" = ubi9-minimal ]; then
		sed -i \
			-e 's!7D8D15CBFC4E62688591FB2633D98517E37ED158!FF8AD1344597106ECE813B918A3872BF3228467C!g' \
			-e 's!EPEL-10!EPEL-9!g' \
			-e 's!epel-release-latest-10!epel-release-latest-9!g' \
			-e 's!--enablerepo=epel --disablerepo=mariadb --releasever=10.1 !!' \
			"$dir/Dockerfile"
	elif [ "$suite" = ubi10-minimal ]; then
		sed -i \
			-e 's!reinstall!install!' \
			"$dir/Dockerfile"
	fi
	# Start using the new executable names
	case "$version$ubi" in
		10.6)
			# quoted $ intentional
			# shellcheck disable=SC2016
			sed -i -e '/bashbrew-architectures/a\
ARG MARIADB_MAJOR=10.6\
ENV MARIADB_MAJOR $MARIADB_MAJOR
' \
				-e 's/" mysql-server/-$MARIADB_MAJOR" mysql-server/' \
				"$dir/Dockerfile"
			;&
		10.6-ubi)
			sed -i -e '/memory\.pressure/,+7d' \
				-e 's/--mariadbd/--mysqld/' \
				"$dir/docker-entrypoint.sh"
			sed -i -e '/--skip-ssl/d' "$dir/docker-entrypoint.sh" "$dir/healthcheck.sh"
			sed -i -e 's/mariadb_upgrade_info/mysql_upgrade_info/' \
				"$dir/docker-entrypoint.sh" "$dir/healthcheck.sh"
			sed -i -e 's/ && userdel.*//' \
				"$dir/Dockerfile"
			sed -i -e '/purge and re-create/{
					n
					s/;/ \/etc\/mysql\/mariadb.conf.d\/50-mysqld_safe.cnf;/}' \
				"$dir/Dockerfile"
			;;
		10.11*)
			sed -i -e 's/mariadb_upgrade_info/mysql_upgrade_info/' \
				-e '/--skip-ssl/d' \
				"$dir/docker-entrypoint.sh" "$dir/healthcheck.sh"
			sed -i -e 's/ && userdel.*//' \
				-e '/purge and re-create/{
					n
					s/;/ \/etc\/mysql\/mariadb.conf.d\/50-mysqld_safe.cnf;/}' \
				"$dir/Dockerfile"
			;;
		*)
			;&
	esac

	if [ -n "$ubi" ]; then
		base=redhat/$suite
	else
		base=ubuntu:$suite
	fi
	# Add version to versions.json
	versionJson="$(jq -e \
		--arg milestone "${version%%-*}" --arg milestoneversion "${version}${ubi}" --arg version "$mariaVersion" --arg fullVersion "$fullVersion" --arg releaseStatus "$releaseStatus" --arg supportType "$supportType" --arg base "$base" --arg arches "${arches# }" \
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
		Preview | Alpha | Beta | Gamma | RC | Stable ) ;; # sanity check
		*) echo >&2 "error: unexpected 'release status' value for $mariaVersion: $releaseStatus"; ;;
	esac

	supportType=$2

	update_version
	ubi=-ubi update_version
}

mariaversion()
{
	# version hacks because our $DOWNLOADS_REST_API
	# seems to never be right on release and has unfinshed support
	# for rolling release versions.
	#if [ "$version" = 11.4 ]; then
	#	mariaVersion=11.4.7;
	#	return
	#fi
	mariaVersion=$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/${version%-*}" \
		| jq -r 'first(.releases[] | .release_id | select(. | test("[0-9]+.[0-9]+.[0-9]+$")))')
	mariaVersion=${mariaVersion//\"}
}

all()
{
	printf '%s\n' "{}" > versions.json

	readarray -O 0 -c 3 -C update_version_array -t release <<< "$(curl -fsSL "$DOWNLOADS_REST_API/mariadb/" \
		| jq -r '.major_releases[] | [ .release_id ], [ .release_status ], [ .release_support_type ]  | @tsv')"
}

in_development()
{
	releaseStatus=Alpha
	supportType=Unknown
	version=$development_version
	mariaVersion=${development_version_real}.0
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
	version="${version%/}"
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

	case "$version" in
	11.7)
		releaseStatus=${release[0]:-Stable}
		supportType=${release[1]:-Short Term Support}
		;;
        11.6)
		releaseStatus=${release[0]:-Stable}
		supportType=${release[1]:-Short Term Support}
		;;
	*)
		releaseStatus=${release[0]:-Unknown}
		supportType=${release[1]:-Unknown}
		;;
	esac

	update_version
done
