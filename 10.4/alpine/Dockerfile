# vim:set ft=dockerfile:
FROM alpine:3.13

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN addgroup -S mysql && adduser -S -D -h /var/lib/mysql -G mysql mysql

# BusyBox date: unrecognized option: rfc-3339=seconds
RUN set -eux; \
	apk add --no-cache \
		coreutils \
		bash \
		pwgen \
		su-exec \
		tzdata

RUN mkdir /docker-entrypoint-initdb.d

ENV GPG_KEYS \
# pub   rsa4096 2016-03-30 [SC]
#         177F 4010 FE56 CA33 3630  0305 F165 6F24 C74C D1D8
# uid           [ unknown] MariaDB Signing Key <signing-key@mariadb.org>
# sub   rsa4096 2016-03-30 [E]
	177F4010FE56CA3336300305F1656F24C74CD1D8 \
	199369E5404BD5FC7D2FE43BCBCB082A1BB943DB

ENV MARIADB_MAJOR 10.4
ENV MARIADB_VERSION 10.4.17

RUN set -eux; \
#_mytopdeps="perl perl-dbi perl-dbd-mysql perl-getopt-long perl-socket perl-term-readkey"
	apk add --no-cache --virtual .build-deps \
		bison \
		cmake \
		curl-dev \
		g++ \
		gcc \
		gnupg \
		libaio-dev \
		libevent-dev \
		linux-headers \
		linux-pam-dev \
		make \
		musl-dev \
		ncurses-dev \
		gnutls-dev \
		readline-dev \
		xz-dev \
		zlib-dev \
	; \
	\
	wget "https://downloads.mariadb.com/MariaDB/mariadb-$MARIADB_MAJOR/source/mariadb-$MARIADB_VERSION.tar.gz.asc"; \
	wget "https://downloads.mariadb.com/MariaDB/mariadb-$MARIADB_MAJOR/source/mariadb-$MARIADB_VERSION.tar.gz"; \
	wget -O sha512sums.txt.asc "https://downloads.mariadb.com/MariaDB/mariadb-$MARIADB_MAJOR/source/sha512sums.txt.asc"; \
	wget -O sha512sums.txt "https://downloads.mariadb.com/MariaDB/mariadb-$MARIADB_MAJOR/source/sha512sums.txt"; \
	export GNUPGHOME="$(mktemp -d)"; \
	for key in $GPG_KEYS; do \
		gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
	done; \
	gpg --batch --verify sha512sums.txt.asc sha512sums.txt; \
	sha512sum -c sha512sums.txt; \
	gpg --batch --verify mariadb-$MARIADB_VERSION.tar.gz.asc mariadb-$MARIADB_VERSION.tar.gz; \
	mkdir -p /usr/src/mariadb; \
	tar -xf mariadb-$MARIADB_VERSION.tar.gz -C /usr/src/mariadb --strip-components=1; \
	gpgconf --kill all; \
	rm -r "$GNUPGHOME" sha512sums.txt.asc sha512sums.txt mariadb-$MARIADB_VERSION.tar.gz.asc mariadb-$MARIADB_VERSION.tar.gz; \
	\
	cd /usr/src/mariadb; \
	cmake . \
		-DBUILD_CONFIG=mysql_release \
		-DCMAKE_INSTALL_PREFIX=/usr \
		-DDEFAULT_CHARSET=utf8mb4 \
		-DDEFAULT_COLLATION=utf8mb4_general_ci \
		-DENABLED_LOCAL_INFILE=ON \
		-DMYSQL_DATADIR=/var/lib/mysql \
		-DMYSQL_UNIX_ADDR=/run/mysqld/mysqld.sock \
		-DPLUGIN_TOKUDB=NO \
		-DSYSCONF2DIR=/etc/my.cnf.d \
		-DSYSCONFDIR=/etc \
		-DWITH_JEMALLOC=NO \
	; \
# print config options to log
	cmake -L; \
	make -j "$(nproc)"; \
	make install; \
	ln -s /usr/scripts/mariadb-install-db /usr/bin/mysql_install_db; \
	cd /; \
	\
	rm -r /usr/src/mariadb; \
	\
# comment out any "user" entires in the MySQL config ("docker-entrypoint.sh" or "--user" will handle user switching)
#	sed -ri 's/^user\s/#&/' /etc/mysql/my.cnf /etc/mysql/conf.d/*; \
# purge and re-create /var/lib/mysql with appropriate ownership
	rm -rf /var/lib/mysql; \
	mkdir -p /var/lib/mysql /var/run/mysqld; \
	chown -R mysql:mysql /var/lib/mysql /var/run/mysqld; \
# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	chmod 777 /var/run/mysqld; \
# don't reverse lookup hostnames, they are usually another container
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-network --virtual .mariadb-rundeps $runDeps; \
	apk del --no-network .build-deps

VOLUME /var/lib/mysql

COPY docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306
CMD ["mysqld"]
