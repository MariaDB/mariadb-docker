# Security Policy

## FAQ

### Why does my security scanner show that an image has CVEs?

See the [Docker Official Images FAQ](https://github.com/docker-library/faq#why-does-my-security-scanner-show-that-an-image-has-cves).

## Supported Versions

Maintained versions are per [Maintaince Policy](https://mariadb.org/about/#maintenance-policy). This will correspond to the major version number directories in this repository.

## Reporting a Vulnerability

The Docker Official Image of MariaDB Server includes binaries from a number of sources:
* `gosu` from https://github.com/tianon/gosu;
* the base container, i.e. Ubuntu;
* `docker-entrypoint.sh`/build and `healthcheck.sh` scripts; and
* MariaDB upstream packages.

`gosu`, based on the upstream [security vulnerability reporting](https://github.com/tianon/gosu/security/advisories/new), should be validated using [govulcheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck) to see if any CVE within these libraries are actually used by the `gosu` executable. This container can pick up a new `gosu` version after there is a upstream release.

The base image of MariaDB Server is based on other Docker Official Images, which are [periodically updated](https://github.com/docker-library/official-images/commits/master/library/ubuntu). When the base Docker Official Image is updated, the MariaDB Server is [also updated](https://github.com/docker-library/repo-info/commits/master/repos/mariadb). Should a freshly pulled current MariaDB Server image be affected by a vulnerability of its base image, please do a [vulnerability report with Docker Official Images](https://github.com/docker-library/official-images/security/advisories/new) according to their [security policy](https://github.com/docker-library/official-images/blob/master/SECURITY.md).

`docker-entrypoint.sh`/build and `healthcheck.sh` scripts - [Report a Vulnerability](../../security/advisories/new).

MariaDB Server upstream packages will process vulnerabilies according to the [security policy](https://mariadb.org/about/security-policy/). When a new MariaDB Server release is published, the Docker Official Image of MariaDB Server will be updated at the same time. Delays in the Docker Official Image may be explained by the FAQ ["I see a change merged here that hasn't shown up on Docker Hub yet?"](##i-see-a-change-merged-here-that-hasnt-shown-up-on-docker-hub-yet).

Vulnerability reports on the content of this repository are encouraged. You can generally expect a reply (acceptance/rejection) within the next business day. An accepted vulnerability should have a fix published on Docker Hub respositories within a week.
