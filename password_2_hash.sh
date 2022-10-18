#!/bin/bash
set -eo pipefail
shopt -s nullglob

command -v openssl >/dev/null || {
  echo "openssl command not found"
  exit 1
}

command -v awk >/dev/null || {
  echo "awk command not found"
  exit 1
}

function hash_pw() {
  openssl sha1 -binary | openssl sha1 -hex -r | awk -F ' ' '{print "*"toupper($1)}'
}

function test_hash() {
  gen_hash=$(echo -n "$1" | hash_pw)
  if [ "$gen_hash" != "$2" ]; then
    exit 1
  fi
}

test_hash 'mariadb' '*54958E764CE10E50764C2EECBB71D01F08549980'

function ask_pw() {
  stty -echo
  head -n 1 | tr -d '\n'
  stty echo
}

echo -n "Password: "
ask_pw | hash_pw
