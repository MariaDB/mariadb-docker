#!/usr/bin/env bash
set -Eeuo pipefail

GLOBIGNORE=examples/:.*/:test/:main/:main-ubi/:12.3*

err() {
  echo >&2 "ERROR: $*"
  exit 1
}

declare -A aliases=(
	#[10.3]='10 latest'
	#[5.5]='5'
)

# "latest", "10", "5", etc aliases are auto-detected in the loop below
declare -A latest=()

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

# needed by .architectures-lib
# https://github.com/docker-library/bashbrew/releases
command -v bashbrew >/dev/null || {
	err "bashbrew: command not found"
}

source '.architectures-lib'

versions=( */ )
versions=( "${versions[@]%/}" )

# sort version numbers with highest first
IFS=$'\n'; versions=( $(echo "${versions[*]}" | sort -rV) ); unset IFS

# get the most recent commit which modified any of "$@"
fileCommit() {
	git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
	local dir="$1"; shift
	(
		cd "$dir"
		fileCommit \
			Dockerfile \
			$(git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						print $i
					}
				}
			')
	)
}

cat <<-EOH
# this file is generated via https://github.com/MariaDB/mariadb-docker/blob/$(fileCommit "$self")/$self

Maintainers: Daniel Black <daniel@mariadb.org> (@grooverdan),
             Daniel Bartholomew <dbart@mariadb.com> (@dbart),
             Faustin Lammler <faustin@mariadb.org> (@fauust)
GitRepo: https://github.com/MariaDB/mariadb-docker.git
Builder: buildkit
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for version in "${versions[@]}"; do
	commit="$(dirCommit "$version")"

	fullVersion="$(git show "$commit":"$version/Dockerfile" | awk '$1 == "ARG" && $2 ~ "MARIADB_VERSION=" { gsub(/^MARIADB_VERSION=|([0-9]+:)|[+].*$/, "", $2); print $2; exit }')"
	releaseStatus="$(grep -m1 'release-status:' "$version/Dockerfile" | cut -d':' -f2)"
	supportType="$(grep -m1 'support-type:' "$version/Dockerfile" | cut -d':' -f2)"

	case $releaseStatus in
	Unknown)
		releaseStatus=Stable
		;&
	Stable)
		suffix=
		;;
	*)
		suffix=-${releaseStatus,,*}
	esac
        # this is for new tagged disto versions
        # so won't attract non-distro tags
        # Not including ubi because UBI base images have
        # a filetime that exceeds MariaDB's releases.
        special=
	# non-ubi gets full version
	if [[ $version =~ .*ubi ]]; then
		ubi=-ubi
	else
		ubi=
		if [[ "$version" == *-* ]]; then # A 10.6-jammy for instance
			special=-${version#*-}
		fi
	fi
	versionAliases=( "${fullVersion}${ubi}${special}" )

	case "${supportType}" in
	"Long Term Support")
		supportType=LTS
		;;
	"Short Term Support")
		supportType=STS
		;;
	*)
		supportType=Unknown
		supportType=STS
	esac

	if [ "$version" != "$fullVersion" ]; then
		versionAliases+=( "${version}" )
	fi

	versionAliases+=( ${aliases[$version]:-} )
	if [ "$releaseStatus" = 'Stable' ] && [ -z "$special" ]; then
		versions=( "${version%%.*}${ubi}" )
		if [ -z "$ubi" ]; then
			versions+=( latest )
		fi
		if [ "$supportType" = LTS ]; then
			versions+=( lts"${ubi}" )
		fi

		for tryAlias in "${versions[@]}"; do
			if [ -z "${latest[$tryAlias]:-}" ]; then
				latest[$tryAlias]="$version"
				versionAliases+=( "$tryAlias" )
			fi
		done
	fi

	from="$(git show "$commit":"$version/Dockerfile" | awk '$1 == "FROM" { print $2; exit }')"
	if [[ "$from" =~ redhat/* ]]; then
		distro="${from#redhat/}"
		suite="${distro%%-*}" # -minimal/init...
		variantAliases=( "${versionAliases[@]/%/${suite#ubi}}" )
	elif [ -z "$special" ]; then # already added
		distro="${from%%:*}" # "debian", "ubuntu"
		suite="${from#"$distro":}" # "jessie-slim", "xenial"
		suite="${suite%-slim}" # "jessie", "xenial"
		variantAliases=( "${versionAliases[@]/%/-${suite}}" )
	else
		# special ones include their distro already
		variantAliases=()
	fi

	versionAliases=( "${variantAliases[@]//latest-/}" "${versionAliases[@]}" )
	versionAliases=( "${versionAliases[@]/%/${suffix}}" )
	arches=$(versionArches "$version")

	for arch in $arches; do
		case $suite in
		ubi*)
			# RPMify the arch
			case $arch in
			arm64v8)
				arch=aarch64 ;;
			amd64)
				arch=x86_64 ;;
			esac
			if ! curl --fail --silent --head "https://archive.mariadb.org/mariadb-${fullVersion}/yum/rhel/${suite#ubi}/${arch}/" > /dev/null 2>&1 ; then
				echo "$arch missing for $fullVersion"
				exit 1
			fi
			;;
		*)
			# Debify the arch
			case $arch in
			arm64v8)
				arch=arm64 ;;
			ppc64le)
				arch=ppc64el ;;
			esac
			if ! curl --fail --silent --head "https://archive.mariadb.org/mariadb-${fullVersion}/repo/${distro}/dists/${suite}/main/binary-${arch}/" > /dev/null 2>&1 ; then
				echo "$arch missing for $fullVersion"
				exit 1
			fi
			;;
		esac
	done

	echo
	cat <<-EOE
		Tags: $(join ', ' "${versionAliases[@]}")
		Architectures: $(join ', ' $arches)
		GitCommit: $commit
		Directory: $version
	EOE
done
