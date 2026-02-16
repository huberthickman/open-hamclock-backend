#######################################################
# Build the real image
#######################################################
FROM debian:13.3-slim

USER root
WORKDIR /opt

# Install prerequisites
COPY docker/package-list.txt /opt
RUN apt update && \
    apt install -y --no-install-recommends $(grep -v '^#' package-list.txt) && \
    apt-get clean && \
    rm -rf package-list.txt /var/lib/apt/lists/* 

# Install hamclock-backend
COPY . /opt/hamclock-backend/
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
    sed 's/^\([^ #]\+[ ]\+\)\{5\}\([^>]\+\)\([> ]\+\)\?\([^ ]*\).*$/echo "  Running: \2"\n\2\3\4/' \
        scripts/crontab > prime_crontabs.sh && \
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
    /usr/sbin/lighttpd-enable-mod ohb-dashboard

# let's rock!
CMD ["/opt/run.sh"]
