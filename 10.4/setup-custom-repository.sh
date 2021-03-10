#!/bin/bash
set -x
usage() {
  echo <<INFO "$(basename "${0}")" --repository REPOSITORY --repository-key KEY
    --repository REPOSITORY path to the MaxScale repository
    --repository-key KEY               URL to the repository key
INFO
}

repository=
key=

while [[ ${1:-} ]]; do
  case "$1" in
    "--repository")
      shift
      repository="$1"
      shift
      ;;
    "--repository-key")
      shift
      key=$1
      shift
      ;;
    "--help")
      usage
      exit
      ;;
    *)
      echo "unknown option $1"
      exit 1
      ;;
  esac
done

if [[ -z $repository ]]; then
  echo "Please specify path to the repository via --repository"
  exit 1
fi

if [[ -z $key ]]; then
  echo "Please specify the URL to the repository key via --key"
  exit 1
fi

echo 'Adding repository signing key'
if apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "${key}"
then
  echo 'Successfully added package signing key'
else
  echo 'Failed to add package signing key'
fi

echo 'Configuring repository'
echo "deb $repository" > /etc/apt/sources.list.d/mariadb.list
cat /etc/apt/sources.list.d/mariadb.list
