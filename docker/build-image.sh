#!/bin/bash

HERE="$(realpath -s "$(dirname "$0")")"
THIS="$(basename "$0")"
BUILD_DIR="$(basename "$HERE")"

IMAGE_BASE=hamclock-be
TAG=test
IMAGE=$IMAGE_BASE:$TAG
VOACAP_VERSION=v.0.7.6

# this hasn't changed since 2020. Also, while we are developing we don't need to keep pulling it.
if [ ! -e voacap-$VOACAP_VERSION.tgz ]; then
    curl https://codeload.github.com/jawatson/voacapl/tar.gz/refs/tags/v.0.7.6 -o voacap-$VOACAP_VERSION.tgz
fi
echo "Currently building version $TAG of $IMAGE_BASE"

pushd "$HERE/.." >/dev/null
docker build --no-cache --rm -t $IMAGE --build-arg "BUILD_DIR=$BUILD_DIR" -f "$BUILD_DIR/Dockerfile" .
popd >/dev/null

# still a work in process
exit

if $(docker image list --format '{{.Repository}}:{{.Tag}}' | grep -qs $IMAGE) ; then
    echo "The docker image for $IMAGE already exists. Please remove it if you want to rebuild."
    exit 2
fi

sed "s/__TAG__/$TAG/" docker-compose.yml.tmpl > docker-compose.yml
