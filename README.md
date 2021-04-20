# https://github.com/MariaDB/mariadb-docker

## Maintained by: [the MariaDB Community](https://github.com/MariaDB/mariadb-docker)

This is the Git repo of the [Docker "Official Image"](https://github.com/docker-library/official-images#what-are-official-images) for [`mariadb`](https://hub.docker.com/_/mariadb/) (not to be confused with any official `mariadb` image provided by MariaDB Corporation). See [the Docker Hub page](https://hub.docker.com/_/mariadb/) for the full readme on how to use this Docker image and for information regarding contributing and issues.

The [full image description on Docker Hub](https://hub.docker.com/_/mariadb/) is generated/maintained over in [the docker-library/docs repository](https://github.com/docker-library/docs), specifically in [the `mariadb` directory](https://github.com/docker-library/docs/tree/master/mariadb).

## See a change merged here that doesn't show up on Docker Hub yet?

For more information about the full official images change lifecycle, see [the "An image's source changed in Git, now what?" FAQ entry](https://github.com/docker-library/faq#an-images-source-changed-in-git-now-what).

For outstanding `mariadb` image PRs, check [PRs with the "library/mariadb" label on the official-images repository](https://github.com/docker-library/official-images/labels/library%2Fmariadb). For the current "source of truth" for [`mariadb`](https://hub.docker.com/_/mariadb/), see [the `library/mariadb` file in the official-images repository](https://github.com/docker-library/official-images/blob/master/library/mariadb).

## FAQ

**How do I reset my password?**

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
CREATE DATABASE IF NOT EXISTS databasename;
GRANT ALL ON databasename.* TO myuser@'%';
```

## Getting Help
If you need help with MariaDB on Docker, the [Docker and MariaDB](https://mariadb.com/kb/en/docker-and-mariadb/) section of the MariaDB Knowledge Base contains lots of helpful info. The Knowledge Base also has a page where you can [Ask a Question](https://mariadb.com/kb/en/docker-and-mariadb/ask). Also see the [Getting Help with MariaDB](https://mariadb.com/kb/en/getting-help-with-mariadb/) article.

On StackExchange, questions tagged with 'mariadb' and 'docker' on the Database Administrators (DBA) StackExchange can be found [here](https://dba.stackexchange.com/questions/tagged/docker+mariadb).

If you run into any bugs or have ideas on new features you can file bug reports and feature requests on the [MariaDB JIRA](https://jira.mariadb.org). File them under the "MDEV" project and "Docker" component to make sure it goes to the correct people. If you are considering submitting a feature or pull request, be sure to check out the [Review Guidelines](https://github.com/docker-library/official-images#review-guidelines) for some helpful information.


---

-	[![build status badge](https://img.shields.io/github/workflow/status/MariaDB/mariadb-docker/GitHub%20CI/master?label=GitHub%20CI)](https://github.com/MariaDB/mariadb-docker/actions?query=workflow%3A%22GitHub+CI%22+branch%3Amaster)

| Build | Status | Badges | (per-arch) |
|:-:|:-:|:-:|:-:|
| [![amd64 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/amd64/job/mariadb.svg?label=amd64)](https://doi-janky.infosiftr.net/job/multiarch/job/amd64/job/mariadb/) | [![arm64v8 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/arm64v8/job/mariadb.svg?label=arm64v8)](https://doi-janky.infosiftr.net/job/multiarch/job/arm64v8/job/mariadb/) | [![ppc64le build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/ppc64le/job/mariadb.svg?label=ppc64le)](https://doi-janky.infosiftr.net/job/multiarch/job/ppc64le/job/mariadb/) | [![put-shared build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/put-shared/job/light/job/mariadb.svg?label=put-shared)](https://doi-janky.infosiftr.net/job/put-shared/job/light/job/mariadb/) |
