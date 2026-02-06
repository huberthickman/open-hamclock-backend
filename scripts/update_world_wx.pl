#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json encode_json);
use File::Path qw(make_path);
use Fcntl qw(:flock);

# -----------------------
# Config
# -----------------------
my $OUT_TXT    = '/opt/hamclock-backend/htdocs/ham/HamClock/worldwx/wx.txt';
my $TMP_DIR    = '/opt/hamclock-backend/tmp/worldwx';
my $CACHE_JSON = "$TMP_DIR/cache.json";
my $STATE_JSON = "$TMP_DIR/state.json";
my $LOCK_FILE  = "$TMP_DIR/.lock";

# How many points per request (keep modest to avoid 5xx; 100-300 is usually safe)
my $CHUNK = $ENV{OPENMETEO_CHUNK} // 200;

# How many requests to attempt per run (this is your main rate limiter)
my $REQS_PER_RUN = $ENV{OPENMETEO_REQS_PER_RUN} // 1;

# Sleep between requests within a run
my $SLEEP_BETWEEN_REQS = $ENV{OPENMETEO_SLEEP} // 1;

# Retry/backoff (kept conservative)
my $MAX_TRIES      = $ENV{OPENMETEO_RETRIES} // 6;
my $BACKOFF_START  = $ENV{OPENMETEO_BACKOFF_START} // 5;
my $BACKOFF_CAP    = $ENV{OPENMETEO_BACKOFF_CAP} // 60;

# -----------------------
# Grid: lat -90..90 step 4, lon -180..180 step 5
# -----------------------
my @LATS = (-90, -86, -82, -78, -74, -70, -66, -62, -58, -54, -50, -46, -42, -38, -34, -30, -26, -22, -18, -14, -10, -6, -2,
             2,   6,  10,  14,  18,  22,  26,  30,  34,  38,  42,  46,  50,  54,  58,  62,  66,  70,  74,  78,  82,  86,  90);

my @LONS = (-180, -175, -170, -165, -160, -155, -150, -145, -140, -135, -130, -125, -120, -115, -110, -105, -100,  -95,  -90,  -85,  -80,  -75,
            -70,  -65,  -60,  -55,  -50,  -45,  -40,  -35,  -30,  -25,  -20,  -15,  -10,   -5,    0,    5,   10,   15,   20,   25,   30,   35,
             40,   45,   50,   55,   60,   65,   70,   75,   80,   85,   90,   95,  100,  105,  110,  115,  120,  125,  130,  135,  140,  145,
            150,  155,  160,  165,  170,  175,  180);

# -----------------------
# JSON helpers
# -----------------------
sub read_json_file {
    my ($path, $default) = @_;
    $default //= {};
    return $default if !-f $path;
    open my $fh, '<', $path or return $default;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $obj = eval { decode_json($raw) };
    return (defined($obj) ? $obj : $default);
}

sub write_json_atomic {
    my ($path, $obj) = @_;
    my $tmp = "$path.$$";
    open my $fh, '>', $tmp or die "ERROR: cannot write $tmp: $!\n";
    print {$fh} encode_json($obj);
    close $fh;
    rename $tmp, $path or die "ERROR: rename $tmp -> $path failed: $!\n";
}

# -----------------------
# Wx mapping (Open-Meteo weather_code -> HamClock-ish token)
# -----------------------
sub wx_from_code {
    my ($code) = @_;
    return 'Unknown' if !defined $code;

    return 'Clear'  if $code == 0;
    return 'Clouds' if $code == 1 || $code == 2 || $code == 3;
    return 'Fog'    if $code == 45 || $code == 48;
    return 'Rain'   if ($code >= 51 && $code <= 67) || ($code >= 80 && $code <= 82);
    return 'Snow'   if ($code >= 71 && $code <= 77) || ($code >= 85 && $code <= 86);
    return 'Thunderstorm' if ($code >= 95 && $code <= 99);

    return 'Clouds';
}

sub fmt_line {
    my ($lat, $lon, $r) = @_;
    return sprintf(
        "%7d %7d %7.1f %7.1f %7.1f %7.1f %7.1f %-14s %7d\n",
        $lat, $lon,
        $r->{temp} // 0,
        $r->{hum}  // 0,
        $r->{mps}  // 0,
        $r->{dir}  // 0,
        $r->{prs}  // 0,
        ($r->{wx}  // 'Unknown'),
        ($r->{tz}  // 0),
    );
}

# -----------------------
# HTTP fetch with retry/backoff
# Returns decoded JSON on success, undef on repeated failure.
# Special-case "Hourly API request limit exceeded" => return undef immediately.
# -----------------------
sub http_get_json_retry {
    my ($ua, $url) = @_;

    my $sleep_s = $BACKOFF_START;

    for (my $try = 1; $try <= $MAX_TRIES; $try++) {
        my $res = $ua->get($url);

        if ($res->is_success) {
            my $body = $res->decoded_content;
            my $j = eval { decode_json($body) };
            return $j if $j;
            warn "WARN: JSON parse failed (try $try/$MAX_TRIES)\n";
        } else {
            my $code = $res->code;
            my $body = $res->decoded_content // '';

            if ($code == 429) {
                if ($body =~ /Hourly API request limit exceeded/i) {
                    warn "WARN: Open-Meteo hourly limit exceeded; stopping requests this run.\n";
                    return undef;
                }
                my $wait = $sleep_s;
                $wait = $BACKOFF_CAP if $wait > $BACKOFF_CAP;
                warn "WARN: Open-Meteo 429. Waiting ${wait}s (try $try/$MAX_TRIES)\n";
                sleep($wait);
                $sleep_s = ($sleep_s < $BACKOFF_CAP) ? ($sleep_s * 2) : $BACKOFF_CAP;
                next;
            }

            if ($code == 500 || $code == 502 || $code == 503 || $code == 504) {
                my $wait = $sleep_s;
                $wait = $BACKOFF_CAP if $wait > $BACKOFF_CAP;
                warn "WARN: Open-Meteo HTTP $code. Waiting ${wait}s (try $try/$MAX_TRIES)\n";
                sleep($wait);
                $sleep_s = ($sleep_s < $BACKOFF_CAP) ? ($sleep_s * 2) : $BACKOFF_CAP;
                next;
            }

            warn "WARN: Open-Meteo HTTP $code (try $try/$MAX_TRIES)\n";
            sleep($sleep_s);
            $sleep_s = ($sleep_s < $BACKOFF_CAP) ? ($sleep_s * 2) : $BACKOFF_CAP;
        }
    }

    return undef;
}

# -----------------------
# Main
# -----------------------
make_path($TMP_DIR) if !-d $TMP_DIR;

# Lock to prevent overlapping runs
open my $lockfh, '>', $LOCK_FILE or die "ERROR: cannot open lock $LOCK_FILE: $!\n";
flock($lockfh, LOCK_EX|LOCK_NB) or die "ERROR: another worldwx run is already in progress\n";

my $cache = read_json_file($CACHE_JSON, {});
my $state = read_json_file($STATE_JSON, { idx => 0 });

# Build points (lon-major blocks, lat ascending)
my @points;
for my $lon (@LONS) {
    for my $lat (@LATS) {
        push @points, [$lat, $lon];
    }
}
my $TOTAL = scalar(@points);
$state->{idx} = 0 if !defined($state->{idx}) || $state->{idx} !~ /^\d+$/ || $state->{idx} >= $TOTAL;

my $ua = LWP::UserAgent->new(
    timeout => 30,
    agent   => 'ohb-worldwx-openmeteo-rot/1.0',
);

# Perform only a small number of requests per run
for (my $r = 0; $r < $REQS_PER_RUN; $r++) {
    my $start = $state->{idx};
    my $end   = $start + $CHUNK - 1;
    $end = $TOTAL - 1 if $end >= $TOTAL;

    my (@lat_list, @lon_list);
    for my $i ($start .. $end) {
        push @lat_list, $points[$i][0];
        push @lon_list, $points[$i][1];
    }

    my $lat_q = join(',', @lat_list);
    my $lon_q = join(',', @lon_list);

    # No timezone=auto; emit TZ=0 for all points
    my $url =
        "https://api.open-meteo.com/v1/forecast"
        . "?latitude=$lat_q"
        . "&longitude=$lon_q"
        . "&current=temperature_2m,relative_humidity_2m,wind_speed_10m,wind_direction_10m,surface_pressure,weather_code"
        . "&wind_speed_unit=ms";

    my $j = http_get_json_retry($ua, $url);
    last if !$j;  # stop requests this run on repeated failure / hourly-limit message

    my @resp = ref($j) eq 'ARRAY' ? @$j : ($j);
    if (@resp != @lat_list) {
        warn "WARN: unexpected response length (got ".scalar(@resp)." expected ".scalar(@lat_list)."); stopping this run\n";
        last;
    }

    for my $k (0 .. $#resp) {
        my $one = $resp[$k];
        my $c = $one->{current} || {};

        my $lat = $lat_list[$k];
        my $lon = $lon_list[$k];
        my $key = "$lat,$lon";

        my $r = {
            temp => $c->{temperature_2m},
            hum  => $c->{relative_humidity_2m},
            mps  => $c->{wind_speed_10m},
            dir  => $c->{wind_direction_10m},
            prs  => $c->{surface_pressure},
            wx   => wx_from_code($c->{weather_code}),
            tz   => 0,
            ts   => time(),
        };

        $cache->{$key} = $r;
    }

    # Persist cache after each successful request
    write_json_atomic($CACHE_JSON, $cache);

    # Advance cursor (wrap)
    $state->{idx} = $end + 1;
    $state->{idx} = 0 if $state->{idx} >= $TOTAL;
    write_json_atomic($STATE_JSON, $state);

    sleep($SLEEP_BETWEEN_REQS) if $SLEEP_BETWEEN_REQS;
}

# Always (re)write wx.txt from cache so clients see a complete file
my $tmp_out = "$OUT_TXT.$$";
open my $out, '>', $tmp_out or die "ERROR: cannot write $tmp_out: $!\n";
print {$out} "#   lat     lng  temp,C     %hum    mps     dir    mmHg    Wx           TZ\n";

for my $lon (@LONS) {
    for my $lat (@LATS) {
        my $key = "$lat,$lon";
        my $r = $cache->{$key} // { temp=>0, hum=>0, mps=>0, dir=>0, prs=>0, wx=>'Unknown', tz=>0 };
        print {$out} fmt_line($lat, $lon, $r);
    }
    print {$out} "\n";
}

close $out;
rename $tmp_out, $OUT_TXT or die "ERROR: rename $tmp_out -> $OUT_TXT failed: $!\n";

exit 0;

