#!/usr/bin/env perl
use strict;
use warnings;

use LWP::UserAgent;
use JSON qw(decode_json);
use Time::Local;
use Text::CSV_XS;

my $URL   = 'https://api.pota.app/spot';
my $OUT   = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/onta.txt';
my $TMP   = "$OUT.tmp";

my $PARKS_CSV = '/opt/hamclock-backend/cache/all_parks_ext.csv';

# Match observed onta.txt size: 97 lines total (header + 96 rows)
my $MAX_ROWS  = 96;
# Observed window in your onta.txt is ~1 hour, so default to 60 minutes
my $MAX_AGE_S = 3600;

sub org_from_ref {
    my ($ref) = @_;
    return 'WWFF' if defined($ref) && $ref =~ /^KFF-/i;
    return 'SOTA' if defined($ref) && $ref =~ m{/};     # e.g. W7O/NC-051
    return 'POTA';
}

sub load_parks_lookup {
    my (%park);

    return %park unless -f $PARKS_CSV;

    open my $fh, '<', $PARKS_CSV or die "Cannot read $PARKS_CSV: $!\n";
    my $csv = Text::CSV_XS->new({ binary => 1, auto_diag => 1 });

    my $header = $csv->getline($fh);
    my %idx;
    for my $i (0..$#$header) {
        my $k = $header->[$i] // next;
        $k =~ s/^"|"$//g;
        $idx{$k} = $i;
    }

    for my $need (qw(reference latitude longitude grid)) {
        die "Missing '$need' column in $PARKS_CSV\n" unless exists $idx{$need};
    }

    while (my $row = $csv->getline($fh)) {
        my $ref = $row->[$idx{reference}] // next;
        $ref =~ s/^"|"$//g;

        my $lat  = $row->[$idx{latitude}];
        my $lng  = $row->[$idx{longitude}];
        my $grid = $row->[$idx{grid}];

        $park{$ref} = {
            lat  => (defined $lat  ? $lat  : ''),
            lng  => (defined $lng  ? $lng  : ''),
            grid => (defined $grid ? $grid : ''),
        };
    }

    close $fh;
    return %park;
}

my %park_lookup = load_parks_lookup();

my $ua = LWP::UserAgent->new(
    timeout => 10,
    agent   => 'HamClock-Backend/1.0',
);

my $resp = $ua->get($URL);
die "Fetch failed: " . $resp->status_line . "\n" unless $resp->is_success;

my $spots = decode_json($resp->decoded_content);
die "Bad JSON (expected ARRAY)\n" unless ref $spots eq 'ARRAY';

my $now = time();

# Keep only newest spot per de-dupe key
my %best;   # key -> row hashref

for my $s (@$spots) {
    next unless ref $s eq 'HASH';

    my $call = $s->{activator} // next;
    my $freq = $s->{frequency} // next;   # kHz
    my $mode = $s->{mode}      // '';
    my $park = $s->{reference} // '';
    my $time = $s->{spotTime}  // next;

    my ($Y,$m,$d,$H,$M,$S) =
        $time =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/
        or next;

    my $epoch = timegm($S,$M,$H,$d,$m-1,$Y);
    next if ($now - $epoch) > $MAX_AGE_S;

    # Frequency: kHz -> Hz
    my $hz = int((0 + $freq) * 1000);

    my $org = org_from_ref($park);

    # Enrich from parks cache when possible (works for POTA refs like US-####)
    my ($grid, $lat, $lng) = ('', 0, 0);
    if ($park && exists $park_lookup{$park}) {
        $grid = $park_lookup{$park}{grid} // '';
        $lat  = $park_lookup{$park}{lat}  // 0;
        $lng  = $park_lookup{$park}{lng}  // 0;
    }

    my $key = join('|', $call, $park, $mode, $hz, $org);

    # Keep the newest record for this key
    if (!exists $best{$key} || $epoch > $best{$key}{epoch}) {
        $best{$key} = {
            call  => $call,
            hz    => $hz,
            epoch => $epoch,
            mode  => $mode,
            grid  => $grid,
            lat   => $lat,
            lng   => $lng,
            park  => $park,
            org   => $org,
        };
    }
}

# Sort newest-first and cap
my @out = sort { $b->{epoch} <=> $a->{epoch} } values %best;
splice(@out, $MAX_ROWS) if @out > $MAX_ROWS;

open my $fh, '>', $TMP or die "Cannot write temp file $TMP: $!\n";
print $fh "#call,Hz,unix,mode,grid,lat,lng,park,org\n";

for my $r (@out) {
    print $fh join(',',
        $r->{call},
        $r->{hz},
        $r->{epoch},
        $r->{mode},
        $r->{grid},
        $r->{lat},
        $r->{lng},
        $r->{park},
        $r->{org},
    ), "\n";
}

close $fh;
rename $TMP, $OUT or die "Rename failed $TMP -> $OUT: $!\n";

