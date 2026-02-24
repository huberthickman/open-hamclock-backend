#!/bin/bash

echo "This image is based on git: '$(cat hamclock-backend/git.version)'"
echo "Start up time: $(date -u +%H:%M:%S)"

echo "Syncing the initial, static directory structure ..."
mkdir -p /opt/hamclock-backend/htdocs/ham
cp -a /opt/hamclock-backend/ham/HamClock /opt/hamclock-backend/htdocs/ham
if [ "$ENABLE_DASHBOARD" == true ]; then
    cp -a /opt/hamclock-backend/ham/dashboard/* /opt/hamclock-backend/htdocs
else
    find /opt/hamclock-backend/htdocs -maxdepth 1 -type f -exec rm -f "{}" +
    cp /opt/hamclock-backend/ham/dashboard/favicon.ico /opt/hamclock-backend/htdocs
    cp /opt/hamclock-backend/ham/dashboard/ascii.txt /opt/hamclock-backend/htdocs
fi

# start the web server
echo "Starting lighttpd ..."
/usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf

# only needs to be primed when container is instantiated
if [ ! -e /opt/hamclock-backend/htdocs/prime_crontabs.done ]; then
    echo "Running OHB for the first time."

    echo "Priming the data set ..."
    /usr/sbin/runuser -u www-data /opt/hamclock-backend/prime_crontabs.sh

    touch /opt/hamclock-backend/htdocs/prime_crontabs.done
    echo "Done! OHB data has been primed."

    LAST_TIME_EPOCH=$(date -u +%s)
else
    echo "OHB was previously installed and does not need to be primed."

    LAST_TIME_EPOCH=$(find /opt/hamclock-backend/htdocs -type f -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d. -f1)
    echo "Last running timestamp found is: '$(date -ud @$LAST_TIME_EPOCH)'"
fi

echo $LAST_TIME_EPOCH > /opt/last-ts-running.txt
echo $(date -u +%s) > /opt/started-running.txt

# start cron
echo "Starting cron ..."
/usr/sbin/cron

echo "OHB is running and ready to use at: $(date -u +%H:%M:%S)"

# hold the script to keep the container running
tail --pid=$(pidof cron) -f /dev/null
