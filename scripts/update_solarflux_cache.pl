#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;

my $URL = 'https://spaceweather.gc.ca/solar_flux_data/daily_flux_values/fluxtable.txt';
my $CACHE = '/opt/hamclock-backend/data/solarflux-cache.txt';
my $MAX_DAYS = 90;

my $ua = LWP::UserAgent->new(timeout => 10);

my $resp = $ua->get($URL);
die "Fetch failed\n" unless $resp->is_success;

# Load existing cache
my %seen;
my @cache;

if (open my $fh, '<', $CACHE) {
    while (<$fh>) {
        chomp;
        my ($d, $v) = split;
        next unless defined $d && defined $v;
        push @cache, [$d, $v];
        $seen{$d} = 1;
    }
    close $fh;
}

# Parse NOAA file
for my $line (split /\n/, $resp->decoded_content) {

    next if $line =~ /^[a-zA-Z-]/;
    next unless $line =~ /^\d{8}\s+\d{6}/;

    my ($Ymd,$time,$flux) = (split /\s+/, $line)[0,1,4];
    next unless defined $flux;

    $Ymd =~ s/(\d{4})(\d{2})(\d{2})/$1-$2-$3/;

    next if $seen{$Ymd.$time};

    push @cache, [$Ymd, sprintf('%d', $flux) ];
    $seen{$Ymd.$time} = 1;
}

# Sort and trim
@cache = sort { $a->[0] cmp $b->[0] } @cache;
@cache = splice(@cache, -$MAX_DAYS) if @cache > $MAX_DAYS;

# Write back
open my $out, '>', $CACHE or die "Write cache failed\n";
for my $e (@cache) {
    print $out "$e->[0] $e->[1]\n";
}
close $out;

