#!/bin/bash
set -eu

declare -A aliases=(
	#[10.3]='10 latest'
	#[5.5]='5'
)

# "latest", "10", "5", etc aliases are auto-detected in the loop below
declare -A latest=()

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

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
# this file is generated via https://github.com/docker-library/mariadb/blob/$(fileCommit "$self")/$self

Maintainers: Tianon Gravi <admwiggin@gmail.com> (@tianon),
             Joseph Ferguson <yosifkit@gmail.com> (@yosifkit)
GitRepo: https://github.com/docker-library/mariadb.git
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for version in "${versions[@]}"; do
	commit="$(dirCommit "$version")"

	fullVersion="$(git show "$commit":"$version/Dockerfile" | awk '$1 == "ENV" && $2 == "MARIADB_VERSION" { gsub(/^([0-9]+:)|[+].*$/, "", $3); print $3; exit }')"

	versionAliases=( $fullVersion )
	if [ "$version" != "$fullVersion" ]; then
		versionAliases+=( $version )
	fi
	versionAliases+=( ${aliases[$version]:-} )

	releaseStatus="$(grep -m1 'release-status:' "$version/Dockerfile" | cut -d':' -f2)"
	if [ "$releaseStatus" = 'Stable' ]; then
		for tryAlias in "${version%%.*}" latest; do
			if [ -z "${latest[$tryAlias]:-}" ]; then
				latest[$tryAlias]="$version"
				versionAliases+=( "$tryAlias" )
			fi
		done
	fi

	from="$(git show "$commit":"$version/Dockerfile" | awk '$1 == "FROM" { print $2; exit }')"
	distro="${from%%:*}" # "debian", "ubuntu"
	suite="${from#$distro:}" # "jessie-slim", "xenial"
	suite="${suite%-slim}" # "jessie", "xenial"

	variantAliases=( "${versionAliases[@]/%/-$suite}" )
	versionAliases=( "${variantAliases[@]//latest-/}" "${versionAliases[@]}" )

	echo
	cat <<-EOE
		Tags: $(join ', ' "${versionAliases[@]}")
		Architectures: $(join ', ' $(versionArches $version))
		GitCommit: $commit
		Directory: $version
	EOE
done
