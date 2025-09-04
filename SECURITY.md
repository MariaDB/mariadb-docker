# Security Policy

## FAQ

### Why does my security scanner show that an image has CVEs?

See the [Docker Official Images FAQ](https://github.com/docker-library/faq#why-does-my-security-scanner-show-that-an-image-has-cves).

## Supported Versions

Maintained versions are per the [Maintenance Policy](https://mariadb.org/about/#maintenance-policy). This will correspond to the major version number directories in this repository.

## Reporting a Vulnerability

The Docker Official Image of MariaDB Server includes binaries from a number of sources:
* `gosu` from https://github.com/tianon/gosu;
* the Base Image; i.e. Ubuntu or Red Hat's UBI;
* Container Scripts; `docker-entrypoint.sh` and `healthcheck.sh`; and
* MariaDB Server; from upstream packages (not from the base image distribution).

### gosu

`gosu`, based on the upstream [security vulnerability reporting](https://github.com/tianon/gosu/security/advisories/new), should be validated using [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck) to see if any CVE within these libraries are actually used by the `gosu` executable. This container can pick up a new `gosu` version after there is a upstream release.

The current `gosu` released version, 1.17, because of the golang runtime at the time of release, reports one finding with `govulncheck`, [GO-2023-1840](https://pkg.go.dev/vuln/GO-2023-1840) (also labeled [CVE-2023-29403](https://www.cve.org/CVERecord?id=CVE-2023-29403)). The end of the `govulncheck` report for GO-2023-1840 states:

  "your code doesn't appear to call these vulnerabilities."

The reason that `govulncheck` reports this is the `gosu` isn't setuid or setgid which is a key aspect of this vulnerability. `docker run --rm mariadb ls -la /usr/local/bin/gosu` can be used to validate the lack of setuid/setgid bits. Further more, the `gosu` will immediately exit if it is run in this vulnerable mode (per [upstream author comment](https://github.com/tianon/gosu/issues/128#issuecomment-1607803883)).

### Base Image

The base image of MariaDB Server is based on other Docker Official Images, which are [periodically updated](https://github.com/docker-library/official-images/commits/master/library/ubuntu). When the base Docker Official Image is updated, the MariaDB Server is [also updated](https://github.com/docker-library/repo-info/commits/master/repos/mariadb). Should a freshly pulled current MariaDB Server image be affected by a vulnerability of its base image, please do a [vulnerability report with Docker Official Images](https://github.com/docker-library/official-images/security/advisories/new) according to their [security policy](https://github.com/docker-library/official-images/blob/master/SECURITY.md).

### Container Scripts

`docker-entrypoint.sh`/build and `healthcheck.sh` scripts - [Report a Vulnerability](../../security/advisories/new).

### MariaDB Server

MariaDB Server upstream packages will process vulnerabilities according to the [security policy](https://mariadb.org/about/security-policy/). When a new MariaDB Server release is published, the Docker Official Image of MariaDB Server will be updated at the same time. Delays in the Docker Official Image may be explained by the FAQ ["I see a change merged here that hasn't shown up on Docker Hub yet?"](##i-see-a-change-merged-here-that-hasnt-shown-up-on-docker-hub-yet).

### Expectations

Vulnerability reports on the content of this repository are encouraged. You can generally expect a reply (acceptance/rejection) within the next business day. An accepted vulnerability should have a fix published on Docker Hub repositories within a week.
