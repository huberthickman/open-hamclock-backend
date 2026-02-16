#!/usr/bin/perl

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP;

my %weather_apis = (
    'weather.gov' => {
        'func' => \&weather_gov,
        'attrib' => 'weather.gov',
    }, 'open-meteo.com' => {
        'func' => \&open_meteo,
        'attrib' => 'open-mateo.com',
        'apikey' => $ENV{'OPEN_METEO_API_KEY'} // "",
    }, 'openweathermap.org' => {
        'func' => \&open_weather,
        'attrib' => 'openweathermap.org',
        'apikey' => $ENV{'OPEN_WEATHER_API_KEY'} // "",
    },
);

my $UA = HTTP::Tiny->new(
    timeout => 5,
    agent   => "HamClock-NOAA/1.1"
);

# -------------------------
# Parse QUERY_STRING
# -------------------------
my %q;
if ($ENV{QUERY_STRING}) {
    for (split /&/, $ENV{QUERY_STRING}) {
        my ($k,$v) = split /=/, $_, 2;
        next unless defined $k;
        $v //= '';
        $v =~ tr/+/ /;
        $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $q{$k} = $v;
    }
}

my ($lat,$lng) = @q{qw(lat lng)};

# -------------------------
# Defaults
# -------------------------
my %wx = (
    city             => "",
    temperature_c    => -999,
    pressure_hPa     => -999,
    pressure_chg     => -999,
    humidity_percent => -999,
    dewpoint         => -999,
    wind_speed_mps   => 0,
    wind_dir_name    => "N",
    clouds           => "",
    conditions       => "",
    attribution      => "",
    timezone         => 0,
);

# -------------------------
# Get the weather
# -------------------------
if (defined $lat && defined $lng) {

    # Timezone approximation (parity with OWM)
    $wx{timezone} = approx_timezone_seconds($lng);

    # 1) points lookup
    if ( ! $weather_apis{'openweathermap.org'}->{'func'}->($lat, $lng, %wx) ) {
        my $return = $weather_apis{'open-meteo.com'}->{'func'}->($lat, $lng, %wx);
    }
}

hc_output(%wx);

exit;

# -------------------------
# Output (HamClock format)
# -------------------------
sub hc_output {
    my ($wx) = @_;
    print <<'HEADER';
HTTP/1.0 200 Ok
Content-Type: text/plain; charset=ISO-8859-1
Connection: close

HEADER

    print <<"BODY";
city=$wx{city}
temperature_c=$wx{temperature_c}
pressure_hPa=$wx{pressure_hPa}
pressure_chg=$wx{pressure_chg}
humidity_percent=$wx{humidity_percent}
dewpoint=$wx{dewpoint}
wind_speed_mps=$wx{wind_speed_mps}
wind_dir_name=$wx{wind_dir_name}
clouds=$wx{clouds}
conditions=$wx{conditions}
attribution=$wx{attribution}
timezone=$wx{timezone}
BODY
}

# -------------------------
# Alternative weather APIs
# -------------------------
sub weather_gov {
    my ($lat, $lng, $wx) = @_;
    my $p = $UA->get("https://api.weather.gov/points/$lat,$lng");
    if ($p->{success}) {
        my $pd = eval { decode_json($p->{content}) };

        if ($pd && $pd->{properties}) {

            # City from relativeLocation
            my $rl = $pd->{properties}->{relativeLocation}->{properties};
            $wx{city} = $rl->{city} if $rl && $rl->{city};

            # Stations URL
            my $stations_url = $pd->{properties}->{observationStations};
            my $s = $UA->get($stations_url);

            if ($s->{success}) {
                my $sd = eval { decode_json($s->{content}) };
                for my $station (@{ $sd->{features} }) {
                    if ($station->{properties}->{stationIdentifier}) {
                        my $stationIdentifier = $station->{properties}->{stationIdentifier};
                        my $o = $UA->get(
                            "https://api.weather.gov/stations/$stationIdentifier/observations/latest"
                        );

                        if ($o->{success}) {
                            my $od = eval { decode_json($o->{content}) };
                            my $p = $od->{properties};

                            $wx{temperature_c}    = val($p->{temperature}->{value});
                            $wx{humidity_percent} = val($p->{relativeHumidity}->{value});
                            $wx{dewpoint}         = val($p->{dewpoint}->{value});
                            $wx{dewpoint}         = calculate_dew_point($wx{temperature_c}, $wx{humidity_percent});
                            $wx{wind_speed_mps}   = val($p->{windSpeed}->{value});
                            $wx{wind_dir_name}    = deg_to_cardinal(val($p->{windDirection}->{value}));

                            if (defined $p->{seaLevelPressure}->{value}) {
                                $wx{pressure_hPa} =
                                    sprintf("%.0f", $p->{seaLevelPressure}->{value} / 100);
                            }

                            $wx{conditions}  = $p->{textDescription} // "";
                            $wx{clouds}      = $p->{textDescription} // "";
                            $wx{attribution} = $weather_apis{'weather.gov'}->{'attrib'},
                            last;
                        }
                    }
                }
            }
        }
    }
}

sub open_meteo {
    my ($lat, $lng, $wx) = @_;
    my $base_url = "https://api.open-meteo.com/v1/forecast";
    my $get_lat_lng = "?latitude=$lat&longitude=$lng";
    my $get_params = 
            "&current=temperature_2m"
            .",relative_humidity_2m"
            .",wind_speed_10m"
            .",wind_direction_10m"
            .",pressure_msl"
            .",weather_code"
            .",dew_point_2m"
            .",cloud_cover"
            ;
    my $get_units ="&wind_speed_unit=ms";

    my $p = $UA->get($base_url.$get_lat_lng.$get_params.$get_units);
    if ($p->{success}) {
        my $pd = eval { decode_json($p->{content}) };
        $wx{temperature_c}    = val($pd->{current}->{temperature_2m});
        $wx{humidity_percent} = val($pd->{current}->{relative_humidity_2m});
        $wx{dewpoint}         = val($pd->{current}->{dew_point_2m});
        $wx{wind_speed_mps}   = val($pd->{current}->{wind_speed_10m});
        $wx{wind_dir_name}    = deg_to_cardinal(val($pd->{current}->{wind_direction_10m}));
        $wx{clouds}           = val($pd->{current}->{cloud_cover});
        $wx{conditions}       = get_wmo_description(val($pd->{current}->{weather_code}));
        $wx{pressure_hPa}     = val($pd->{current}->{pressure_msl});
        $wx{attribution} = $weather_apis{'open-meteo.com'}->{'attrib'};
        return 1;
    } else {
        $wx{conditions}       = $p->{reason};
        return 0;
    }
}

sub open_weather {
    my ($lat, $lng, $wx) = @_;
    my $base_url = "https://api.openweathermap.org/data/2.5/weather";
    my $get_lat_lng = "?lat=$lat&lon=$lng";
    my $get_api = "&appid=$weather_apis{'openweathermap.org'}->{'apikey'}";
    my $get_params = "&units=metric";

    my $p = $UA->get($base_url.$get_lat_lng.$get_api.$get_params);
    if ($p->{success}) {
        my $pd = eval { decode_json($p->{content}) };
        #$wx{city}             = $pd->{city}->{name};
        $wx{temperature_c}    = val($pd->{main}->{temp});
        $wx{humidity_percent} = val($pd->{main}->{humidity});
        $wx{dewpoint}         = calculate_dew_point($wx{temperature_c}, $wx{humidity_percent});
        $wx{wind_speed_mps}   = val($pd->{wind}->{speed});
        $wx{wind_dir_name}    = deg_to_cardinal(val($pd->{wind}->{deg}));
        $wx{clouds}           = val($pd->{clouds}->{all});
        $wx{conditions}       = $pd->{weather}[0]->{description};
        $wx{pressure_hPa}     = val($pd->{main}->{sea_level});
        $wx{attribution} = $weather_apis{'openweathermap.org'}->{'attrib'},
        return 1;
    } else {
        return 0;
    }
}

# -------------------------
# Helpers
# -------------------------
sub val {
    my ($v) = @_;
    return -999 unless defined $v;
    return sprintf("%.2f",$v);
}

sub deg_to_cardinal {
    my ($deg) = @_;
    return "N" unless defined $deg;
    my @d = qw(N NE E SE S SW W NW);
    return $d[int((($deg % 360)+22.5)/45)%8];
}

sub calculate_dew_point {
    my ($temp_c, $humidity) = @_;
    # Standard constants for the Magnus-Tetens formula
    my $a = 17.27;
    my $b = 237.7;
    my $alpha = (($a * $temp_c) / ($b + $temp_c)) + log($humidity/100.0);
    return ($b * $alpha) / ($a - $alpha);
}

sub approx_timezone_seconds {
    my ($lng) = @_;
    return 0 unless defined $lng;

    # Longitude to timezone hours (15° per hour), rounded
    my $hours = int(($lng / 15) + ($lng >= 0 ? 0.5 : -0.5));

    # OpenWeatherMap-style offset: hours * 3600
    return $hours * 3600;
}

sub get_wmo_description {
    my ($code) = @_;

    return 'Clear'           if $code == 0;
    return 'Partly Cloudy'   if $code >= 1  && $code <= 3;
    return 'Hazy/Dusty'      if $code >= 4  && $code <= 9;
    return 'Foggy'           if $code == 10 || ($code >= 40 && $code <= 49);
    return 'Drizzle'         if $code >= 50 && $code <= 59;
    return 'Rain'            if $code >= 60 && $code <= 65;
    return 'Freezing Rain'   if $code >= 66 && $code <= 67;
    return 'Snow'            if ($code >= 68 && $code <= 69) || ($code >= 70 && $code <= 79);
    return 'Rain Showers'    if $code >= 80 && $code <= 82;
    return 'Snow Showers'    if $code >= 85 && $code <= 86;
    return 'Thunderstorm'    if $code >= 95 && $code <= 99;

    return 'Unknown Code';
}
