# Docker Library Official Image for MariaDB

This is the Git repository of the [Docker Library "Official Image"](https://github.com/docker-library/official-images#what-are-official-images) for [`mariadb`](https://hub.docker.com/_/mariadb/).

**Maintained by: the [MariaDB Foundation and Community](https://mariadb.org)**

## FAQ

### How do I use this MariaDB image?

See [the Docker Hub page](https://hub.docker.com/_/mariadb/) for the full README on how to use this container image.

### How do I reset my database password?

[One useful way](https://github.com/MariaDB/mariadb-docker/issues/365#issuecomment-816367940) to do this is to create an `initfile.sql` file that contains (to cover all bases) something like the following:

```sql
CREATE USER IF NOT EXISTS root@localhost IDENTIFIED BY 'thisismyrootpassword';
SET PASSWORD FOR root@localhost = PASSWORD('thisismyrootpassword');
GRANT ALL ON *.* TO root@localhost WITH GRANT OPTION;
CREATE USER IF NOT EXISTS root@'%' IDENTIFIED BY 'thisismyrootpassword';
SET PASSWORD FOR root@'%' = PASSWORD('thisismyrootpassword');
GRANT ALL ON *.* TO root@'%' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS myuser@'%' IDENTIFIED BY 'thisismyuserpassword';
SET PASSWORD FOR myuser@'%' = PASSWORD('thisismyuserpassword');
CREATE DATABASE IF NOT EXISTS mydatabasename;
GRANT ALL ON mydatabasename.* TO myuser@'%';
```

Adjust *myuser* and *mydatabasename* as applicable.

Run with:
```shell
[docker|podman] run --volume [path-of-initfile.sql]:/docker-entrypoint-initdb.d --volume [data]:/var/lib/mysql --init-file=/docker-entrypoint-initdb.d/initfile.sql
```

After this run, the changes are made and future runs can be made as you did them before.

### I see a change merged here that hasn't shown up on Docker Hub yet?

For more information about the full official images change life-cycle, see [the "An image's source changed in Git, now what?" FAQ entry](https://github.com/docker-library/faq#an-images-source-changed-in-git-now-what).

For outstanding `mariadb` image Pull Requests (PRs), check [PRs with the "library/mariadb" label on the official-images repository](https://github.com/docker-library/official-images/labels/library%2Fmariadb). For the current "source of truth" for [`mariadb`](https://hub.docker.com/_/mariadb/), see [the `library/mariadb` file in the official-images repository](https://github.com/docker-library/official-images/blob/master/library/mariadb).

### Why don't you provide an Alpine-based image?

In order to provide our users with the most stable image possible, we only create container images from packages directly from MariaDB, and not distribution packages. This is partially from the [repeatability criteria](https://github.com/docker-library/official-images#repeatability) of Docker Library, but it's mainly due to the stability of the image being dependent on it being tested using [CI](https://buildbot.mariadb.org/) prior to release. As MariaDB doesn't test in an [Alpine Linux](https://alpinelinux.org) environment, or against [musl libc](https://musl.libc.org/) on which Alpine is based, we cannot in good conscience deliver an untested implementation. This may change in the future.

There have been unexpected behaviours and bugs reported against MariaDB for musl-based interfaces against architectures that MariaDB simply isn't tested on. MariaDB Server developers find it hard to test, diagnose and fix bugs against those environments. While Alpine Linux is a beautiful Linux distribution, the level of MariaDB testing from this, or any distribution, falls short of what we want to provide our users.

Musl's [key principles](https://musl.libc.org/about.html) favor simplicity and size over performance, and there are aspects of MariaDB that are highly dependent on the performance of the libc functions, particularly the ones highly optimized in glibc by architecture developers for optimal performance. A future consideration of musl for container images will require benchmarking to ensure that we are offering our users a non-degraded performance.

[LinuxServer.io](https://fleet.linuxserver.io/image?name=linuxserver/mariadb) offers an Alpine Linux-based MariaDB if you still want this. However, it is less supported by MariaDB Server developers or not supported in this community.

### An Alpine Linux image would be smaller, right?

Yes, by probably less than 100M. MariaDB is a database where a basic data directory exceeds this difference. We aren't going to sacrifice performance and reliability to save a comparatively small amount of storage.

### I'd like the MariaDB on Architecture X?

To support MariaDB on a new architecture, it needs to be tested in CI against this architecture before release. Please search [MariaDB JIRA](https://jira.mariadb.org) and create a Task requesting the architecture or vote/watch on an existing issue. The votes/watcher numbers on the issues are used to prioritize work. If accepted due to popular demand, the CI against this architecture will result in packages that can used in the container manifest in the same way as the current supported architectures.

But Alpine/Debian/Disto X supports this already? Sorry, we aren't going to compromise the quality of this container by providing less tested images on any architecture.


## Getting Help

If you need help with MariaDB on Docker, the [Docker and MariaDB](https://mariadb.com/kb/en/docker-and-mariadb/) section of the MariaDB Knowledge Base contains lots of helpful info. The Knowledge Base also has a page where you can [Ask a Question](https://mariadb.com/kb/en/docker-and-mariadb/ask). Also see the [Getting Help with MariaDB](https://mariadb.com/kb/en/getting-help-with-mariadb/) article.

On StackExchange, questions tagged with 'mariadb' and 'docker' on the Database Administrators (DBA) StackExchange can be found [here](https://dba.stackexchange.com/questions/tagged/docker+mariadb).


## Reporting a Bug / Feature Request

If you run into any bugs or have ideas on new features you can file bug reports and feature requests on the [MariaDB JIRA](https://jira.mariadb.org) instance. File them under the "MDEV" project and "Docker" component to make sure it goes to the correct people.

## Contributing a Bug Fix / Feature Request

Contributing changes involves [creating a pull request](https://docs.github.com/en/articles/creating-a-pull-request).

If you are considering submitting a feature or pull request, be sure to check out the [Review Guidelines](https://github.com/docker-library/official-images#review-guidelines) for some helpful information.

The development of the container image here aims to provide complete backwards compatibility for existing users. If there is a case where the container previously started and behaved in a certain way, after your change, it should, under the same circumstances, behave in the same way.

Please update the tests to verify the behaviour of your bug fix or feature request in the [.test](https://github.com/MariaDB/mariadb-docker/tree/master/.test) directory by extending [run.sh](https://github.com/MariaDB/mariadb-docker/blob/master/.test/run.sh) and including supporting files. Tests here run on [GitHub Actions](https://github.com/MariaDB/mariadb-docker/actions) and also in [Buildbot](https://buildbot.mariadb.org/) (Soon) so please avoid adding uncommon dependencies to running a test if possible. If additional dependencies are needed, please check for their existence and skip the test if this isn't available.

Changes to the Dockerfile should be done at the top level [Docker.template](https://github.com/MariaDB/mariadb-docker/blob/master/Dockerfile.template) and entrypoint changes in [entrypoint.sh](https://github.com/MariaDB/mariadb-docker/blob/master/docker-entrypoint.sh). Run [update.sh](https://github.com/MariaDB/mariadb-docker/blob/master/update.sh) to propagate these changes to the major version (10.X) folders underneath.

### Coding Conventions

Please write code in a similar style to what is already there. Use tab indents on the entrypoint script.

`_xxx` functions are intended for internal use and may be changed in the future. If you write a shell function that might be useful to a `/docker-entrypoint-initdb.d` script to use, prefix it with `docker_` and it will be considered a stable script interface.

If you need a change to occur in a specific major version only, change the `update.sh` script to ensure that its `Dockerfile` / `docker-entrypoint.sh` generates version-specific changes.

#### Branches

There are two permanent branches:
* master - changes that work with the currently released MariaDB packages go here.
* next - changes that work with currently unreleased MariaDB code changes, including unreleased MariaDB versions.

The "next" branch may be rebased on master occasionally and will be used in the [buildbot testing](https://buildbot.mariadb.org/#/builders/amd64-rhel8-dockerlibrary).

### Testing Changes

To build, you can use [docker build](https://docs.docker.com/engine/reference/commandline/build/), [buildah bud](https://buildah.io/), [podman build](http://docs.podman.io/en/latest/markdown/podman-build.1.html) or any other container tool that understands Dockerfiles. The only argument needed is the build directory (10.X).

Run:
```
.test/run {container hash/tag}
```

This will run through all current tests and the new tests you have created. The key aspect is that the script should error returning a non-zero exit code if the test fails.

### Git Commits

Commit messages should describe why this change is occurring, what problem it is solving, and if the solution isn't immediately obvious, some rationale as to why it was implemented in its current form. 

If you are making multiple independent changes please create separate pull requests per change.

If the changes are a number of distinct steps, a commit per logical progression would be appreciated.

It is preferred if you commit the changes to the major version directories generated by `update.sh` in a separate commit. This way, if you need to rebase on the latest version, this commit can be amended, and the code changes are easy to read and review.

### Bug Fixes

Bug fixes are most welcome and should include a full description of the problem being fixed in the commit message.

### Feature Requests

Before investing too much time in a feature request, please discuss its use on a [JIRA issue](https://jira.mariadb.org), a [github issue](https://github.com/MariaDB/mariadb-docker/issues), or with someone on [Zulip](https://mariadb.zulipchat.com/#narrow/stream/118759-general) (create a New Topic).

After a feature is written, please help get it used by improving the documentation to detail how to use the newly added feature.

## Improving the Documentation

The [full image description on Docker Hub](https://hub.docker.com/_/mariadb/) is generated/maintained over in [the docker-library/docs repository](https://github.com/docker-library/docs), specifically in [the `mariadb` directory](https://github.com/docker-library/docs/tree/master/mariadb).

To change the documentation, please contribute a [pull request](https://github.com/docker-library/docs/pulls) or [issue](https://github.com/docker-library/docs/issues) against the [Docker Library docs repository](https://github.com/docker-library/docs).


## Current CI Status

[![build status badge](https://img.shields.io/github/workflow/status/MariaDB/mariadb-docker/GitHub%20CI/master?label=GitHub%20CI)](https://github.com/MariaDB/mariadb-docker/actions?query=workflow%3A%22GitHub+CI%22+branch%3Amaster)

[![Buildbot of latest MariaDB](https://img.shields.io/badge/dynamic/json?label=buildbot%20CI%20upstream&query=$.builds[0].state_string&url=https%3A%2F%2Fbuildbot.mariadb.org%2Fapi%2Fv2%2Fbuilders%2Famd64-rhel8-dockerlibrary%2Fbuilds%3Flimit%3D1%26order%3D-number)](https://buildbot.mariadb.org/#/builders/amd64-rhel8-dockerlibrary)

| Docker Library Official Images CI Status (released changes) |
|:-:|
| [![amd64 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/amd64/job/mariadb.svg?label=amd64)](https://doi-janky.infosiftr.net/job/multiarch/job/amd64/job/mariadb/) |
| [![arm64v8 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/arm64v8/job/mariadb.svg?label=arm64v8)](https://doi-janky.infosiftr.net/job/multiarch/job/arm64v8/job/mariadb/) |
| [![ppc64le build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/ppc64le/job/mariadb.svg?label=ppc64le)](https://doi-janky.infosiftr.net/job/multiarch/job/ppc64le/job/mariadb/) |
| [![s390x build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/ppc64le/job/mariadb.svg?label=s390x)](https://doi-janky.infosiftr.net/job/multiarch/job/s390x/job/mariadb/) |
| [![put-shared build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/put-shared/job/light/job/mariadb.svg?label=put-shared)](https://doi-janky.infosiftr.net/job/put-shared/job/light/job/mariadb/) |
