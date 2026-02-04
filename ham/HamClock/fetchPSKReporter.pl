#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;
use CGI qw(param);
use XML::LibXML;
use Digest::SHA qw(sha1_hex);
use Fcntl qw(:flock);

# ---- Tunables ----
my $LIMIT        = 120;   # max rows returned
my $FRESH_TTL    = 30;    # seconds: serve cached body if newer than this
my $STALE_TTL    = 3600;  # seconds: allow stale cache up to this age on upstream failure
my $CACHE_DIR    = "/opt/hamclock-backend/tmp/hamclock-psk-cache";
my $UA_TIMEOUT   = 6;     # seconds: upstream HTTP timeout
my $HARD_DEADLINE = 8;    # seconds: hard wall-clock deadline for entire CGI

# Debug (goes to lighttpd error.log)
print STDERR "psk-cache: using CACHE_DIR=$CACHE_DIR\n";
print STDERR "psk-cache: euid=$> egid=$) pid=$$\n";

# Ensure cache dir exists (log failures instead of silently ignoring)
if (!-d $CACHE_DIR) {
    if (!mkdir $CACHE_DIR) {
        print STDERR "psk-cache: mkdir $CACHE_DIR failed: $!\n";
        # Continue without cache if we cannot create it
    }
}

sub norm_grid {
    my ($g) = @_;
    return '' unless defined $g;
    $g =~ s/[^A-Z0-9]//gi;
    $g = uc($g);
    $g = substr($g, 0, 6) if length($g) > 6;
    return $g;
}

sub http_reply {
    my ($body) = @_;
    $body = '' unless defined $body;

    print "Content-Type: text/plain; charset=ISO-8859-1\r\n";
    print "Connection: close\r\n";
    print "Cache-Control: no-store\r\n";
    print "Content-Length: " . length($body) . "\r\n";
    print "\r\n";
    print $body;
    exit;
}

sub cache_path_for_key {
    my ($key) = @_;
    my $h = sha1_hex($key);
    return "$CACHE_DIR/psk_$h.cache";
}

sub read_cache {
    my ($path) = @_;
    return (undef, undef) unless $path && -f $path;

    my @st = stat($path);
    my $mtime = $st[9];

    open my $fh, '<', $path or do {
        print STDERR "psk-cache: open for read failed $path: $!\n";
        return (undef, undef);
    };
    local $/;
    my $body = <$fh>;
    close $fh;

    return ($body, $mtime);
}

sub write_cache {
    my ($path, $body) = @_;
    return unless $path && defined $body;

    open my $fh, '>', $path or do {
        print STDERR "psk-cache: open for write failed $path: $!\n";
        return;
    };
    flock($fh, LOCK_EX) or print STDERR "psk-cache: flock failed $path: $!\n";
    print $fh $body or print STDERR "psk-cache: write failed $path: $!\n";
    close $fh or print STDERR "psk-cache: close failed $path: $!\n";
    print STDERR "psk-cache: wrote " . length($body) . " bytes to $path\n";
}

# ---- Parameters (HamClock uses ofgrid/bygrid + maxage seconds) ----
my $grid   = norm_grid(param('ofgrid') || param('bygrid') || '');
my $maxage = param('maxage') || 1800;

if (!$grid || $maxage !~ /^\d+$/ || $maxage < 1) {
    http_reply("ERROR=Invalid parameters\n");
}

# Cache key: per grid + window size (and limit so response shape stays consistent)
my $cache_key  = "grid=$grid|maxage=$maxage|limit=$LIMIT";
my $cache_file = cache_path_for_key($cache_key);

# Serve fresh cache immediately if available
if (-f $cache_file) {
    my ($cached_body, $mtime) = read_cache($cache_file);
    if (defined $cached_body && defined $mtime) {
        my $age = time() - $mtime;
        if ($age <= $FRESH_TTL) {
            print STDERR "psk-cache: serving fresh cache $cache_file age=${age}s\n";
            http_reply($cached_body);
        }
    }
}

# Build upstream URL (PSKReporter retrieve API; grid query uses modify=grid)
my $url = sprintf(
    "https://retrieve.pskreporter.info/query?receiverCallsign=%s&flowStartSeconds=-%d&rronly=1&noactive=1&modify=grid",
    $grid, $maxage
);

# Hard deadline for entire CGI execution to prevent hangs
local $SIG{ALRM} = sub { die "HARD_TIMEOUT\n" };

my $resp;
my $xml;

my $ok = eval {
    alarm($HARD_DEADLINE);

    my $ua = LWP::UserAgent->new(
        timeout   => $UA_TIMEOUT,
        agent     => 'HamClock-Compat/1.3',
        env_proxy => 0,
    );

    print STDERR "psk: fetching $url\n";
    $resp = $ua->get($url);
    print STDERR "psk: fetch done status=" . $resp->status_line . "\n";

    die "UPSTREAM_HTTP\n" if !$resp->is_success;

    my $parser = XML::LibXML->new(no_network => 1);
    $xml = $parser->load_xml(string => $resp->decoded_content);

    alarm(0);
    1;
};

my $err = $@;
alarm(0);

if (!$ok) {
    print STDERR "psk: upstream failure: $err";

    # Serve stale cache if available and not too old
    my ($cached_body, $mtime) = read_cache($cache_file);
    if (defined $cached_body && defined $mtime) {
        my $age = time() - $mtime;
        if ($age <= $STALE_TTL) {
            print STDERR "psk-cache: serving stale cache $cache_file age=${age}s\n";
            http_reply($cached_body);
        }
    }

    http_reply("ERROR=PSK Reporter fetch failed\n");
}

# ---- Build response body (buffered so Content-Length is correct) ----
my $now = time();
my @lines;
my $count = 0;

for my $node ($xml->findnodes('//receptionReport')) {
    last if $count >= $LIMIT;

    my $t = $node->getAttribute('flowStartSeconds') || next;
    next if ($now - $t) > $maxage;

    # HamClock ordering: receiver then sender
    my $rx_grid = norm_grid($node->getAttribute('receiverLocator'));
    my $rx_call = uc($node->getAttribute('receiverCallsign') // '');
    my $tx_grid = norm_grid($node->getAttribute('senderLocator'));
    my $tx_call = uc($node->getAttribute('senderCallsign')   // '');
    my $mode    = $node->getAttribute('mode') // '';
    my $hz      = $node->getAttribute('frequency');
    my $snr     = $node->getAttribute('sNR');

    next unless $rx_grid && $tx_grid;

    $hz  = 0 unless defined $hz  && $hz  =~ /^\d+$/;
    $snr = 0 unless defined $snr && $snr =~ /^-?\d+$/;
    next if $hz == 0;

    push @lines, sprintf("%d,%s,%s,%s,%s,%s,%d,%d\n",
        $t, $rx_grid, $rx_call, $tx_grid, $tx_call, $mode, $hz, $snr
    );

    $count++;
}

my $body = join('', @lines);

# Write cache (even if empty; empty can be a valid result)
if (-d $CACHE_DIR) {
    write_cache($cache_file, $body);
} else {
    print STDERR "psk-cache: CACHE_DIR missing, skipping write\n";
}

http_reply($body);

