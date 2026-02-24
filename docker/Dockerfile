#######################################################
# Multi-stage build
#######################################################

#######################################################
# build voacap
#######################################################
FROM debian:13.3-slim AS build-voacap

USER root
WORKDIR /opt

# Install voap build prerequisites
COPY docker/package-list-voacap.txt /opt
COPY docker/dvoacap.tgz /opt

# Build the voacap artifacts
RUN apt update && \
    apt install -y --no-install-recommends $(grep -v '^#' package-list-voacap.txt) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /opt/package-list-voacap.txt && \
    # \
    # move this and packages into a build \
    tar xzf dvoacap.tgz && \
    pip install dvoacap-python-main/. --break-system-packages && \
    rm -Rf dvoacap-python-main

#######################################################
# Build the real image
#######################################################
FROM debian:13.3-slim

USER root
WORKDIR /opt

COPY docker/package-list.txt /opt

# Install prerequisites
RUN apt update && \
    apt install -y --no-install-recommends $(grep -v '^#' package-list.txt) && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /opt/package-list.txt

# the OHB tree
COPY . /opt/hamclock-backend/
# Copy voacap after python was installed above
COPY --from=build-voacap /usr/local/lib/python3.13/dist-packages/ /usr/local/lib/python3.13/dist-packages/

# Install hamclock-backend
RUN cd /opt/hamclock-backend && \
    # \
    # make directory structure \
    mkdir -p \
        tmp \
        logs \
        cache \
        data \
        htdocs && \
    mv  docker/run.sh /opt && \
    # \
    # cron is tightly coupled to the type of python install. cron is written for pyenv. however \
    # when there is no pip or pyenv, python runs from /usr. \
    sed -i 's|^VENV=.*|VENV=/usr|' scripts/crontab && \
    # \
    # This crazy line takes the crontab file, removes the stderr redirect and adds echos to track progress. \
    # It generates a file that will be run only once on a fresh install \
    awk '/^[0-9\*]/ {full=$0; $1=$2=$3=$4=$5=""; sub(/^[ \t]+/, "", $0); exec=$0; sub(/[[:space:]]*[>|].*$/, "", exec); print "echo \"Running: " exec "\""; print $0; next} {print}' scripts/crontab | sed 's/[[:space:]]*2>&1//g' > prime_crontabs.sh && \
    # \
    # set permissions \
    chown -R www-data:www-data . && \
    chmod +x scripts/* prime_crontabs.sh /opt/run.sh /opt/hamclock-backend/lighttpd-conf/env-gen.sh && \
    # \
    # fontconfig needs a writeable cache directory \
    mkdir -p /var/www/.fontconfig && \
    chown -R www-data:www-data /var/www/.fontconfig && \
    # \
    # set up cron \
    mv scripts/crontab /var/spool/cron/crontabs/www-data && \
    chown www-data:crontab /var/spool/cron/crontabs/www-data && \
    chmod 600 /var/spool/cron/crontabs/www-data && \
    # \
    # set up logrotate \
    mv ohb.logrotate /etc/logrotate.d/ohb && \
    # \
    # set up lighttpd \
    cp lighttpd-conf/*.conf /etc/lighttpd/conf-available/ && \
    /usr/sbin/lighty-enable-mod accesslog && \
    /usr/sbin/lighttpd-enable-mod hamclock && \
    /usr/sbin/lighttpd-enable-mod ohb-dashboard && \
    /usr/sbin/lighttpd-enable-mod voacap-proxy && \
    # \
    # ImageMagick policy parameters need to be increased \
    sed -i 's/name="memory" value="[^"]*"/name="memory" value="2GiB"/' /etc/ImageMagick-?/policy.xml && \
    sed -i 's/name="disk" value="[^"]*"/name="disk" value="8GiB"/' /etc/ImageMagick-?/policy.xml

# let's rock!
CMD ["/opt/run.sh"]
