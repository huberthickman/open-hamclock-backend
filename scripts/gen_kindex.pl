#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;
use File::Temp qw(tempfile);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Copy qw(move);

# NOAA source (daily geomagnetic indices; includes 3-hour planetary Kp as last 8 fields)
my $URL = 'https://services.swpc.noaa.gov/text/daily-geomagnetic-indices.txt';

# Paths
my $TMPDIR = '/opt/hamclock-backend/tmp';
my $OUT    = '/opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt';

# HamClock client expects exactly 72 3-hour Kp values (oldest -> newest)
# define KP_VPD 8 number of values per day
# define KP_NHD 7 N historical days
# define KP_NPD 2 N predicted days
# define KP_NV ((KP_NHD+KP_NPD)*KP_VPD) total Kp values

my $KP_NV  = 72;

# Ensure directories exist
my $out_dir = dirname($OUT);
for my $d ($TMPDIR, $out_dir) {
    if (!-d $d) {
        make_path($d, { mode => 0755 })
            or die "ERROR: failed to create $d: $!\n";
    }
    die "ERROR: $d exists but is not writable\n" unless -w $d;
}

my $ua = LWP::UserAgent->new(
    timeout => 20,
    agent   => 'HamClock-kindex-backend/1.1',
);

my $resp = $ua->get($URL);
die "ERROR: fetch failed: " . $resp->status_line . "\n"
    unless $resp->is_success;

my @kp_series;

# Parse NOAA file
for my $line (split /\n/, $resp->decoded_content) {
    next if $line =~ /^\s*#/;
    next unless $line =~ /^\d{4}\s+\d{2}\s+\d{2}\b/;

    my @f = split /\s+/, $line;
    next unless @f >= 8;

    # Planetary Kp floats are the LAST 8 fields
    my @kp = @f[-8 .. -1];

    for my $v (@kp) {
        # Robustness: skip placeholders/future slots and non-numeric tokens
        next if !defined($v) || $v !~ /^-?\d+(?:\.\d+)?$/;
        next if $v < 0;  # NOAA uses negative values for future/unavailable slots
        push @kp_series, sprintf('%.2f', $v);
    }
}

# If we somehow got nothing, emit a safe fixed-length file rather than a short one
if (!@kp_series) {
    @kp_series = ('0.00') x $KP_NV;
}

# Keep only the newest KP_NV values (if we have more)
@kp_series = @kp_series[-$KP_NV .. -1] if @kp_series > $KP_NV;

# If we have fewer than KP_NV, left-pad with the oldest available value
# so we always emit exactly KP_NV lines.
if (@kp_series < $KP_NV) {
    my $pad = $KP_NV - @kp_series;
    unshift @kp_series, ($kp_series[0]) x $pad;
}

# Write atomically
my ($fh, $tmp) = tempfile('kindexXXXX', DIR => $TMPDIR, UNLINK => 0);

print $fh "$_\n" for @kp_series;
close $fh or die "ERROR: close($tmp) failed: $!\n";

move $tmp, $OUT or die "ERROR: move($tmp -> $OUT) failed: $!\n";

exit 0;

