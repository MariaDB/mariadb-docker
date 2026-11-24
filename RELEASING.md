# Releasing

This document is for maintainers.

## How publishing works

The `mariadb` images on Docker Hub are not pushed from this repository. The Docker Library team builds them from a manifest, [`library/mariadb`](https://github.com/docker-library/official-images/blob/master/library/mariadb) in the official-images repository, which pins every image to a directory and a commit here. A release therefore has two halves:

1. **This repository:** commit version directories that pin the new MariaDB packages.
2. **official-images:** open a pull request that points `library/mariadb` at those commits.

Two scripts connect them:

| Script | Role |
|--------|------|
| [update.sh](update.sh) | Asks the [MariaDB Downloads REST API](https://downloads.mariadb.org/rest-api/mariadb/) for the latest release, status and support type of each major. It writes them into the version directories, generated from `Dockerfile*.template` and the scripts, and into [`versions.json`](#versionsjson). |
| [generate-stackbrew-library.sh](generate-stackbrew-library.sh) | Turns the committed version directories into the `library/mariadb` manifest. It decides the tags (`latest`, `lts`, `11`, `-rc`…) from the release status and support type stamped in each Dockerfile. GitHub CI builds and tests the same list. |

The rules behind every release:

* **Directories decide what ships.** Every version directory is published unless it is excluded through `GLOBIGNORE` in `generate-stackbrew-library.sh`.
* **The release status decides the tags.** Only Stable versions get the floating tags (`11`, `latest`, `lts`), and each goes to the highest version that qualifies. Other statuses get a suffix instead (`13.1-rc`).
* **Packages come first.** Images install the packages from `archive.mariadb.org`, and `generate-stackbrew-library.sh` fails if any architecture's packages are missing there. Don't start until MariaDB has published the release.

## Where images are built

The images from this repository are built in three places.  
Only the Docker Library pipeline is part of a release. The other two are checks along the way.

| Pipeline | Builds | MariaDB packages | Publishes to | Purpose |
|----------|--------|------------------|--------------|---------|
| Docker Library | The commits listed in `library/mariadb` | Released (`archive.mariadb.org`) | Docker Hub `mariadb` | The official images |
| GitHub CI ([ci.yml](.github/workflows/ci.yml)) | Every push and PR here, for every published directory | Released | `ghcr.io/mariadb/mariadb` (from `master` only) | Testing changes to this repository |
| [Buildbot](https://buildbot.mariadb.org) | This repository's `next` branch, for each server CI build | Unreleased, from MariaDB Server CI | `quay.io/mariadb-foundation/mariadb-devel` | Testing unreleased server code in the image |

## Kinds of release

| Release | What changes here | Example |
|---------|-------------------|---------|
| Maintenance (quarterly point releases) | Version bumps in the existing directories | `d8991eb` release bump |
| New major version | Add `X.Y/` and `X.Y-ubi/`. Add `X.Y*` to `GLOBIGNORE` until it is ready to publish, usually at RC. Update `development_version_real` (see [below](#the-development-image-main-and-development_version_real)) | 13.1: `95bb038`, `7359e74`, `1a4c8e9` |
| GA of a major | Status changes from RC to Stable, which moves `latest`/`lts` and the major tag | `7359e74` 13.0.2 GA |
| End of life | Delete `X.Y/` and `X.Y-ubi/` | `91f4c52` 12.2 EOL |


## Steps

1. **Check the release is out** in the Downloads API.
2. **Regenerate:** branch from `next` and run `./update.sh`.
3. **Apply the release-kind changes** from the table above.
4. **Review the diff**, especially `# release-status:` and `# release-support-type:`, which decide the tags.
5. **Build and test:** `docker build -t mariadb:test 11.8 && .test/run.sh mariadb:test`.
6. **Open a PR to `next`** on `MariaDB/mariadb-docker`. Once it is merged, merge `next` into `master`. CI on `master` pushes the images to `ghcr.io/mariadb/mariadb`.
7. **Generate the manifest** from a clean checkout of `master`: `./generate-stackbrew-library.sh > mariadb`. It must exit 0.
8. **Open the official-images PR:** replace `library/mariadb` in a fork of [docker-library/official-images](https://github.com/docker-library/official-images) with the generated file, titled like `MariaDB 2026Q4 part 1`. Check the bot's tag diff for `latest`, `lts` and the major tags.
9. **Wait** for the Docker Library maintainers to merge and publish (see [Current CI Status](README.md#current-ci-status)).

## Pitfalls

* **Commit first.** The manifest script reads both `HEAD` and the working tree, so untracked or uncommitted changes break it or change the tags.
* **Push before generating the manifest.** Each `GitCommit` is fetched from `MariaDB/mariadb-docker`, not your fork.
* **Packages may be missing** for an architecture (or e.g. `mariadb-server-galera`). Wait, or make a temporary change in the `case` block of `update_version()` (e.g. `769f60c`) and revert it later.

## The development image: `main/` and `development_version_real`

`main/` and `main-ubi/` hold the image for MariaDB Server's unreleased `main` branch. [Buildbot](#buildbot) builds them; they are never published to Docker Hub.

`main/` is named after a branch, so `update.sh` can't take a version from the directory name. `development_version_real` in `update.sh` supplies it. The image reports that version, and the entrypoint uses it to decide whether `mariadb-upgrade` is needed.

**Keep it at the major.minor of the server's `main` branch** ([`VERSION`](https://github.com/MariaDB/server/blob/main/VERSION)). When that moves, usually as a new `X.Y/` is added here (e.g. `7359e74`, 13.0 → 13.1), update it, run `./update.sh main main-ubi`, and commit to `next` too, since that is the branch Buildbot builds.

## `versions.json`

A machine-readable summary of the version directories, written by `update.sh` for outside tools ([#516](https://github.com/MariaDB/mariadb-docker/pull/516)). Nothing here, in CI or in Buildbot reads it.

## Buildbot

Buildbot is MariaDB Server's CI ([MariaDB/buildbot](https://github.com/MariaDB/buildbot)). It checks that the image still works with the next server release before that release exists. After each server package build it clones this repository's `next` branch, builds the matching `X.Y/` directory (or `main/` if there is none) against the CI packages, runs `.test/run.sh`, and pushes the result to `quay.io/mariadb-foundation/mariadb-devel`. See the Docker Library builder in [master-nonlatent](https://github.com/MariaDB/buildbot/blob/main/master-nonlatent/README.md) and its [`docker-library-*.sh` scripts](https://github.com/MariaDB/buildbot/tree/main/scripts).

What this means here:

* **`next` must work with unreleased server code**, because it is what Buildbot builds.
* **Buildbot has its own copy of the version → base OS mapping** (`hasDockerLibrary` in `utils.py`, mirroring `suites` in `update.sh`). When a version moves to a new base OS, update it there too.
