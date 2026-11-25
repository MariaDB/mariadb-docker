#!/bin/bash
# Tests for healthcheck.sh option handling (datadir and defaults files)
# Sourced by run.sh — do not execute directly
# shellcheck disable=SC2154

# Runs healthcheck.sh in the container as the mysql user. As root,
# root@localhost unix_socket auth would hide missing credentials.
# Globals:
#   cid
# Arguments:
#   healthcheck.sh options
healthcheck_as_mysql() {
  docker exec --user mysql "${cid}" healthcheck.sh "$@"
}

# Asserts healthcheck.sh, run as the mysql user, fails.
# Arguments:
#   Reason, then healthcheck.sh options
healthcheck_as_mysql_fails() {
  local reason="$1"
  shift
  if healthcheck_as_mysql "$@"; then
    die "healthcheck $* passed, expected failure: ${reason}"
  fi
}

# Copies a .my-healthcheck.cnf to a new directory with a wrong password.
# Globals:
#   cid
# Arguments:
#   Source .my-healthcheck.cnf, target directory
make_stale_healthcheck_cnf() {
  docker exec --user mysql "${cid}" bash -c \
    "mkdir -p '$2' && sed -e 's/^password=.*/password=stale/' '$1' \
      > '$2/.my-healthcheck.cnf'"
}

test_healthcheck_default_datadir() {
  local cnf=/var/lib/mysql/.my-healthcheck.cnf

  runandwait -e MARIADB_ROOT_PASSWORD=soverysecret "${image}"

  healthcheck_as_mysql --connect --innodb_initialized \
    || die "healthcheck as mysql should use ${cnf}"
  # --su-mysql needs root, which UBI images (USER mysql) don't default to
  docker exec --user root "${cid}" healthcheck.sh --su-mysql --connect \
    --innodb_initialized || die "healthcheck --su-mysql should use ${cnf}"

  healthcheck_as_mysql --datadir=/nonexistent --connect --innodb_initialized \
    || die "--datadir without a cnf should fall back to ${cnf}"

  healthcheck_as_mysql_fails "--no-defaults reads no cnf" \
    --no-defaults --connect --innodb_initialized
  healthcheck_as_mysql_fails "empty --defaults-extra-file means none" \
    --defaults-extra-file --connect --innodb_initialized

  # An explicit --defaults-extra-file wins over --datadir in either order
  make_stale_healthcheck_cnf "${cnf}" /tmp/stale
  healthcheck_as_mysql_fails "stale cnf has a wrong password" \
    --datadir=/tmp/stale --connect --innodb_initialized
  healthcheck_as_mysql --defaults-extra-file="${cnf}" --datadir=/tmp/stale \
    --connect --innodb_initialized \
    || die "--defaults-extra-file before --datadir should win"
  healthcheck_as_mysql --datadir=/tmp/stale --defaults-extra-file="${cnf}" \
    --connect --innodb_initialized \
    || die "--defaults-extra-file after --datadir should win"
  healthcheck_as_mysql_fails "--no-defaults after --datadir reads no cnf" \
    --datadir=/var/lib/mysql --no-defaults --connect --innodb_initialized

  killoff
}

test_healthcheck_custom_datadir() {
  local datadir=/var/lib/mysql/data

  runandwait -e MARIADB_ROOT_PASSWORD=soverysecret "${image}" \
    --datadir="${datadir}"

  healthcheck_as_mysql --datadir="${datadir}" --connect --innodb_initialized \
    || die "healthcheck should use ${datadir}/.my-healthcheck.cnf"
  healthcheck_as_mysql_fails "no cnf in the default datadir" \
    --connect --innodb_initialized
  healthcheck_as_mysql_fails "--no-defaults before --datadir reads no cnf" \
    --no-defaults --datadir="${datadir}" --connect --innodb_initialized
  healthcheck_as_mysql --no-defaults --datadir="${datadir}" --connect \
    || die "--no-defaults --datadir should still connect"
  healthcheck_as_mysql_fails "--no-defaults isn't undone by a group suffix" \
    --no-defaults --defaults-group-suffix=_x --connect --innodb_initialized

  # A stale cnf in the default location must not stick once --datadir
  # is given, even after a test already ran with it.
  make_stale_healthcheck_cnf "${datadir}/.my-healthcheck.cnf" /var/lib/mysql
  healthcheck_as_mysql --connect --datadir="${datadir}" --innodb_initialized \
    || die "--datadir after a test should switch to its cnf"
  healthcheck_as_mysql_fails "--datadir is applied in argument order" \
    --innodb_initialized --datadir="${datadir}"

  killoff
}
