# vim:set ft=dockerfile:
FROM debian:stretch-slim
ENV DEBIAN_VERSION stretch
ENV MARIADB_MAJOR 10.3
ENV MARIADB_VERSION 1:10.3.8+maria~stretch

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

# Add a few packages we'll be needing later on.
# wget and apt-transport-https for installing Percona repo and tools
# gpg so we can add the keys for the MariaDB repo using apt-key
RUN set -ex; \
	\
	fetchDeps=' \
    apt-transport-https \
    apt-utils \
		ca-certificates \
    dirmngr \
    gosu \
    gpg \
    software-properties-common \
    wget \
	'; \
	apt-get update; \
	apt-get install -y --no-install-recommends $fetchDeps
  
# Add the MariaDB repository, per https://downloads.mariadb.org/mariadb/repositories/
# Note: We can't do this before the packages above is installed, because we need gpg.
RUN apt-key adv --recv-keys --keyserver keyserver.ubuntu.com 0xF1656F24C74CD1D8
RUN add-apt-repository 'deb [arch=amd64] http://mirrors.dotsrc.org/mariadb/repo/10.3/debian $DEBIAN_VERSION main'

RUN { \
		echo 'Package: *'; \
		echo 'Pin: release o=MariaDB'; \
		echo 'Pin-Priority: 999'; \
} > /etc/apt/preferences.d/mariadb

# Install the Percona repository
# https://www.percona.com/doc/percona-xtrabackup/LATEST/installation/apt_repo.html
RUN wget https://repo.percona.com/apt/percona-release_0.1-6.$(lsb_release -sc)_all.deb; \
  dpkg -i percona-release_0.1-6.$(lsb_release -sc)_all.deb; \
  rm percona-release_0.1-6.$(lsb_release -sc)_all.deb

# Pin Percona repository
RUN { \
		echo 'Package: *'; \
		echo 'Pin: release o=Percona Development Team'; \
		echo 'Pin-Priority: 998'; \
	} > /etc/apt/preferences.d/percona


RUN mkdir /docker-entrypoint-initdb.d

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
		echo "mariadb-server-$MARIADB_MAJOR" mysql-server/root_password password 'unused'; \
		echo "mariadb-server-$MARIADB_MAJOR" mysql-server/root_password_again password 'unused'; \
	} | debconf-set-selections \
	&& apt-get update \
	&& apt-get install -y \
		"mariadb-server=$MARIADB_VERSION" \
# percona-xtrabackup is installed at the same time so that `mysql-common` is only installed once from just mariadb repos
		percona-xtrabackup-24 \
		socat \
# comment out any "user" entires in the MySQL config ("docker-entrypoint.sh" or "--user" will handle user switching)
	&& sed -ri 's/^user\s/#&/' /etc/mysql/my.cnf /etc/mysql/conf.d/* \
# purge and re-create /var/lib/mysql with appropriate ownership
	&& rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld \
	&& chown -R mysql:mysql /var/lib/mysql /var/run/mysqld \
# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	&& chmod 777 /var/run/mysqld \
# comment out a few problematic configuration values
	&& find /etc/mysql/ -name '*.cnf' -print0 \
		| xargs -0 grep -lZE '^(bind-address|log)' \
		| xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/' \
# don't reverse lookup hostnames, they are usually another container
	&& echo '[mysqld]\nskip-host-cache\nskip-name-resolve' > /etc/mysql/conf.d/docker.cnf

# Cleanup
RUN rm -rf /var/lib/apt/lists/*; \
  apt-get purge -y --auto-remove $fetchDeps

VOLUME /var/lib/mysql

COPY docker-entrypoint.sh /usr/local/bin/
RUN ln -s usr/local/bin/docker-entrypoint.sh / # backwards compat
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306
CMD ["mysqld"]
