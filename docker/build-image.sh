#!/bin/bash

# Variables to set
IMAGE_BASE=komacke/open-hamclock-backend
VOACAP_VERSION=v.0.7.6
HTTP_PORT=80
ONLY_COMPOSE=false

# Don't set anything past here
TAG=$(git describe --exact-match --tags 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "NOTE: Not currently on a tag. Using 'latest'."
    echo
    TAG=latest
    # should we use the git hash?
    #TAG=$(git rev-parse --short HEAD)
fi

IMAGE=$IMAGE_BASE:$TAG
CONTAINER=${IMAGE_BASE##*/}

# Get our directory locations in figured out
HERE="$(realpath -s "$(dirname "$0")")"
THIS="$(basename "$0")"
cd $HERE

RETVAL=0

usage() {
    cat<<EOF
$THIS: 
    -c: build compose only
    -p <port>: set the http port
EOF
}

main() {

    while getopts ":p:ch" opt; do
        case $opt in
            c)
                ONLY_COMPOSE=true
                ;;
            p)
                HTTP_PORT="$OPTARG"
                ;;
            h)
                usage
                exit 0
                ;;
            \?) # Handle invalid options
                echo "Invalid option: -$OPTARG" >&2
                exit 1
                ;;
            :) # Handle options requiring an argument but none provided
                echo "Option -$OPTARG requires an argument." >&2
                exit 1
                ;;
        esac
    done

    if [ $ONLY_COMPOSE == true ]; then
        make_docker_compose
        compose_done_message
    else
        do_all
        build_done_message
    fi
}

do_all() {
    get_voacap
    make_docker_compose
    warn_image_tag
    build_image
}

get_voacap() {
    # this hasn't changed since 2020. Also, while we are developing we don't need to keep pulling it.
    if [ ! -e voacap-$VOACAP_VERSION.tgz ]; then
        curl -s https://codeload.github.com/jawatson/voacapl/tar.gz/refs/tags/v.0.7.6 -o voacap-$VOACAP_VERSION.tgz
    fi
}

make_docker_compose() {
    echo "Creating docker compose file for image: '$IMAGE_BASE:$TAG', port '$HTTP_PORT'"
    # make the docker-compose file
    sed "s|__IMAGE__|$IMAGE|" docker-compose.yml.tmpl > docker-compose.yml
    sed -i "s/__CONTAINER__/$CONTAINER/" docker-compose.yml
    sed -i "s/__HTTP_PORT__/$HTTP_PORT/" docker-compose.yml
}

warn_image_tag() {
    if $(docker image list --format '{{.Repository}}:{{.Tag}}' | grep -qs $IMAGE) && [ $TAG != latest ]; then
        echo "The docker image for '$IMAGE' already exists. Please remove it if you want to rebuild."
        # NOT ENFORCING THIS YET
        #exit 2
    fi
}

build_image() {
    # Build the image
    echo
    echo "Building image for '$IMAGE_BASE:$TAG'"
    pushd "$HERE/.." >/dev/null
    docker build --rm -t $IMAGE -f docker/Dockerfile .
    RETVAL=$?
    popd >/dev/null
}

compose_done_message() {
    echo
    echo "If this is the first time you are running OHB, run setup first:"
    echo "    docker-ohb-setup.sh"
    echo
    echo "To start the container, launch with docker compose:"
    echo "    docker compose up -d"
}

build_done_message() {
    if [ $RETVAL -eq 0 ]; then
        # basic info
        echo
        echo "Completed building '$IMAGE'."
        compose_done_message
    else
        echo "build failed with error: $RETVAL"
    fi
}

main "$@"
exit $RETVAL
