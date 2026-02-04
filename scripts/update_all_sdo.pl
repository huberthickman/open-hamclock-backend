#!/usr/bin/env perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use LWP::UserAgent;
use Digest::SHA qw(sha1_hex);
use Compress::Zlib qw(compress);

my $OUT_DIR   = "/opt/hamclock-backend/htdocs/ham/HamClock/maps/SDO";
my $CACHE_DIR = "/opt/hamclock-backend/tmp/sdo-cache";
my @SIZES     = (170, 340, 510, 680);

# SDO MP4 sources (from sdo.cpp)
my %MP4 = (
  comp => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_211193171.mp4",
  hmib => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_HMIB.mp4",
  hmiic=> "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_HMIIC.mp4",
  a131 => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0131.mp4",
  a193 => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0193.mp4",
  a211 => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0211.mp4",
  a304 => "https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0304.mp4",
);

# Output filenames (must match client expectations)
sub bmp_name {
  my ($key, $n) = @_;
  return "f_211_193_171_${n}.bmp" if $key eq 'comp';
  return "latest_${n}_HMIB.bmp"   if $key eq 'hmib';
  return "latest_${n}_HMIIC.bmp"  if $key eq 'hmiic';
  return "f_131_${n}.bmp"         if $key eq 'a131';
  return "f_193_${n}.bmp"         if $key eq 'a193';
  return "f_211_${n}.bmp"         if $key eq 'a211';
  return "f_304_${n}.bmp"         if $key eq 'a304';
  die "unknown key: $key";
}

sub run_cmd {
  my (@cmd) = @_;
  system(@cmd) == 0 or die "command failed: @cmd\n";
}

sub fetch_mp4 {
  my ($ua, $url) = @_;
  make_path($CACHE_DIR);

  # cache filename based on URL
  my $fn = "$CACHE_DIR/" . sha1_hex($url) . ".mp4";

  # conditional GET if we already have it
  my $req = HTTP::Request->new(GET => $url);
  if (-f $fn) {
    my $mtime = (stat($fn))[9];
    $req->header('If-Modified-Since' => HTTP::Date::time2str($mtime));
  }

  my $resp = $ua->request($req);

  if ($resp->code == 304 && -f $fn) {
    return $fn; # unchanged
  }

  die "fetch failed $url: " . $resp->status_line . "\n"
    unless $resp->is_success;

  open my $fh, ">:raw", $fn or die "write $fn: $!\n";
  print {$fh} $resp->content;
  close $fh;

  return $fn;
}

sub bmp_from_mp4 {
  my ($mp4, $bmp_out, $n) = @_;

  make_path(dirname($bmp_out));

  # Extract near the end (latest frame), then scale/crop to NxN and write BMP
  run_cmd(
    "ffmpeg",
    "-hide_banner", "-loglevel", "error",
    "-y",
    "-sseof", "-0.5",
    "-i", $mp4,
    "-vframes", "1",
    "-vf", "scale=${n}:${n}:force_original_aspect_ratio=increase,crop=${n}:${n}",
    $bmp_out
  );
}

sub zlib_compress_file {
  my ($bmp, $z_out) = @_;

  open my $in,  "<:raw", $bmp  or die "read $bmp: $!\n";
  local $/;
  my $data = <$in>;
  close $in;

  my $z = compress($data);
  die "zlib compress failed for $bmp\n" unless defined $z;

  open my $out, ">:raw", $z_out or die "write $z_out: $!\n";
  print {$out} $z;
  close $out;
}

sub main {
  make_path($OUT_DIR);
  my $ua = LWP::UserAgent->new(timeout => 30, agent => "hamclock-sdo-backend/1.0");

  for my $key (qw(comp hmib hmiic a131 a193 a211 a304)) {
    my $url = $MP4{$key};
    my $mp4 = fetch_mp4($ua, $url);

    for my $n (@SIZES) {
      my $bmp = "$OUT_DIR/" . bmp_name($key, $n);
      my $z   = $bmp . ".z";

      bmp_from_mp4($mp4, $bmp, $n);
      zlib_compress_file($bmp, $z);

      # Optional: keep BMP too, or delete it if you only want .z served
      # unlink $bmp or die "unlink $bmp: $!\n";
      print "wrote $z\n";
    }
  }
}

main();

