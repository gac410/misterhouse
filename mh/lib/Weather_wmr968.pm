use strict;

package Weather_wmr968;

=begin comment
# =============================================================================
# 11/18/01
Tom Vanderpool modified Bruce Winter's wx200 code to enable use of it
for the OS wmr968/918 and Radio Shack Accuweather Wireless weather stations.
The wx200 ~ wmr918 ~ wmr968 from what I could tell. It seems the main difference
in the wx200 and the 918/968 is the format of the data returned. The difference
between the 918 and the 968 that I found reference to was that the 918 is wired
and the 968 is wireless. Radio Shack has an Accuweather Wireless Weather Station
(63-1016) which is what I have.

 This mh code reads data from the Radio Shack Weather station but should work on the
918 & 968.

One of the big differences that will be seen when comparing this code to
Bruce's original is that the offsets have changed and the data is grouped
differently. With his, all the temperatures seemed to be returned at once
while with mine, all the inside readings are returned in one chunk.
(temp, humid, dew etc)

I also used the FULL data stream (including the first 2 FF hex bytes)
which means that you will need to add 2 to the offsets given in the
definition (they ignored the first 2 bytes).

And it appears that when in a called subroutine, there is one byte added
to the array so I had to compensate for that where it occurred.

# To use it, add these mh.ini parms
#  serial_wmr968_port      = COM7
#  serial_wmr968_baudrate  = 9600
#  serial_wmr968_handshake = dtr
#  serial_wmr968_datatype  = raw
#  serial_wmr968_module    = Weather_wmr968
#  serial_wmr968_skip      =  # Use to ignore bad sensor data.  e.g. TempOutdoor,
#                              HumidOutdoor,WindChill
# altitude = 1000 # In feet, used to find sea level barometric pressure
# in the RS weather station, it adjusts for sea level and gives a direct
# reading so altitude is not needed
#
# A complete usage example is at:
#    http://misterhouse.net/mh/code/bruce/weather_monitor.pl
# Lots of other good Wmr968 software links at:
#    http://www.qsl.net/zl1vfo/wx200/wx200.htm
# -----------------------------------------------------------------------------
# 24/11/03   1.6   Dominique Benoliel	Correct bugs and improvements
# - test for WMR928 Weather station (France)
# - Correct bug if not enough data and only 255 data (1 byte) for the first
#   pass : test data length lower than 3 (headers+device type)
# - Replace Batt. value 100% by 1=power and 0=low (better for test)
# - add $$wptr{WindGustOver} : 1=over, 0=normal
# - add $$wptr{WindAvgOver} : 1=over, 0=normal
# - add $$wptr{WindChillNoData} : 1=nodata, 0=normal
# - add $$wptr{WindChillOver} : 1=over, 0=normal
# - add $$wptr{DateMain} : format YYMMDDHHMM
# - add $$wptr{MinuteMain} : format MM
# - add $$wptr{RainRateOver} : 1=over, 0=normal
# - add $$wptr{RainTotalOver} : 1=over, 0=normal
# - add $$wptr{RainYestOver} : 1=over, 0=normal
# - add $$wptr{RainTotalStartDate} : format YYMMDDHHMM
# - add $$wptr{"ChannelSpare"} : channel 1, 2 ou 3 for extra sensor
# - add $$wptr{"DewSpareUnder1"} : 1=under, 0=normal
# - add $$wptr{"DewSpareUnder2"} : 1=under, 0=normal
# - add $$wptr{"DewSpareUnder3"} : 1=under, 0=normal
# - add $$wptr{DewOutdoorUnder} : 1=under, 0=normal
# - add	$$wptr{"TempSpareOverUnder1"} : -1=under, 1=over
# - add	$$wptr{"TempSpareOverUnder2"} : -1=under, 1=over
# - add	$$wptr{"TempSpareOverUnder3"} : -1=under, 1=over
# - add $$wptr{TempIndoorOverUnder} : -1=under, 1=over
# - add $$wptr{DewIndoorUnder} : 1=under, 0=normal
# - add $$wptr{uom_wind}
# - add $$wptr{uom_temp}
# - add $$wptr{uom_baro}
# - add $$wptr{uom_rain}
# - add $$wptr{uom_rainrate}
# - add mh.ini or mh.private.ini parameters :
#	default_uom_temp : 0=C, 1=F
#	default_uom_baro : 0=mb, 1=inHg
#	default_uom_wind : 0=mph, 1=kph
#	default_uom_rain : 0=mm, 1=in
#	default_uom_rainrate : 0=mm/hr, 1=in/hr
# - Suppress data $$wptr{WindAvgDir} : no average wind direction for wmr928,
#   wmr928 and wmr968
# - produce more lisible debug mode
# - Add device type TH (thermo only=4)
# 01/10/05   1.7   Dominique Benoliel
# - Calculate pressure sea level
# 01/23/05   1.8   Dominique Benoliel
# - make necessary conversions. Store data in global weather variable and use
#   the mh parameters weather_uom_...
# =============================================================================
=cut
my ($wmr968_port, %skip);

sub startup {
    $wmr968_port = new  Serial_Item(undef, undef, 'serial_wmr968');
    &::MainLoop_pre_add_hook(\&Weather_wmr968::update_wmr968_weather, 1 );
    %skip = map {$_, 1} split(',', $main::config_parms{serial_wmr968_skip}) if $main::config_parms{serial_wmr968_skip};
}

sub update_wmr968_weather {
    return unless my $data = said $wmr968_port;
    # Process data, and reset incomplete data not processed this pass
    my $debug = 1 if $main::Debug{weather};
    my $remainder = &read_wmr968($data, \%main::Weather, $debug);
    set_data $wmr968_port $remainder if $remainder;
}

# Category=Weather
# Parse wx200 datastream into array pointed at with $wptr
# Lots of good info on the Wmr968 from: http://www.peak.org/~stanley/wmr918/dataspec
# Set up array of data types, including group index,
# group name, length of data, and relevant subroutine

# tv changed table to reflect wmr968 values
# wx_datatype : data type, nb byte, function
my %wx_datatype = (0x0 => ['wind',    11, \&wx_wind],
                   0x1 => ['rain',    16, \&wx_rain],
                   0x2 => ['temp',     9, \&wx_spare],
                   0x3 => ['temp',     9, \&wx_outside],
                   0x4 => ['temp',     7, \&wx_spare],
                   0x5 => ['inside',  13, \&wx_inside],
                   0x6 => ['inside',  14,  \&wx_inside],
                   0xe => ['seq',      5,  \&wx_seq],
                   0xf => ['date',     9,  \&wx_time]);

sub read_wmr968 {
    my ($data, $wptr, $debug) = @_;

    $$wptr{uom_wind} = "mph";
    $$wptr{uom_temp} = "F";
    $$wptr{uom_baro} = "inHg";
    $$wptr{uom_rain} = "in";
    $$wptr{uom_rainrate} = "in/hr";

    my @data = unpack('C*', $data);
    print "Data read : #@data#\n" if $debug;

    # Test if we have headers and device type, if not return what is left for next pass
    if (@data < 3) {
        printf("     Not enough data, length<3, return data for next pass\n") if $debug;
        return pack('C*', @data);
	}

    while (@data) {
        my $group = $data[2];  # tv changed from 0
        my $dtp = $wx_datatype{$group};

        # Check for valid datatype
        unless ($dtp) {
            my $length = @data;
            printf("     Bad weather data = group(%x) length($length)\n", $group);
            return;
        }
        # If we don't have enough data, return what is left for next pass
        if ($$dtp[1] > @data) {
            printf("     Not enough data, return data for next pass\n") if $debug;
            return pack('C*', @data);
        }

        # Pull out the number of bytes needed for this data type
        my @data2 = splice(@data, 0, $$dtp[1]);

        # Get the checksum (last byte)
        my $checksum1 = pop @data2;
	# Control the checksum
        my $checksum2 = 0;
	# Sum of the data send (include header)
        for (@data2) {
            $checksum2 += $_;
        }
	# Control only the lower byte (lower 8 bits of the sum)
        $checksum2 &= 0xff;
        if ($checksum1 != $checksum2) {
            print "     Warning, bad wx200 type=$$dtp[0] checksum: cs1=$checksum1 cs2=$checksum2\n";
            print "     data2 is @data2\ndata is @data\ngroup is $group\n\n";
            next;
        }

        # Process the data
        &{$$dtp[2]}($wptr, $debug, @data2);

	# Make some conversion if necessary
        if ($main::config_parms{weather_uom_temp} eq 'C') {
      		$$wptr{TempOutdoor} = $$wptr{TempOutdoor_ws};
      		$$wptr{TempIndoor} = $$wptr{TempIndoor_ws};
      		$$wptr{TempSpare1} = $$wptr{TempSpare1_ws};
      		$$wptr{TempSpare2} = $$wptr{TempSpare2_ws};
      		$$wptr{TempSpare3} = $$wptr{TempSpare3_ws};
      		$$wptr{DewSpare1} = $$wptr{DewSpare1_ws};
      		$$wptr{DewSpare2} = $$wptr{DewSpare2_ws};
      		$$wptr{DewSpare3} = $$wptr{DewSpare3_ws};
      		$$wptr{DewOutdoor} = $$wptr{DewOutdoor_ws};
      		$$wptr{DewIndoor} = $$wptr{DewIndoor_ws};
      		$$wptr{WindChill} = $$wptr{WindChill_ws};
    		}
        if ($main::config_parms{weather_uom_baro} eq 'mb') {
      		$$wptr{Barom} = $$wptr{Barom_ws};
      		$$wptr{BaromSea} = $$wptr{BaromSea_ws};
    		}
    	if ($main::config_parms{weather_uom_wind} eq 'kph') {
      		$$wptr{WindGustSpeed} = &main::convert_mile2km($$wptr{WindGustSpeed});
      		$$wptr{WindAvgSpeed} = &main::convert_mile2km($$wptr{WindAvgSpeed});
    		}
    	if ($main::config_parms{weather_uom_wind} eq 'm/s') {
      		$$wptr{WindGustSpeed} = $$wptr{WindGustSpeed_ws};
      		$$wptr{WindAvgSpeed} = $$wptr{WindAvgSpeed_ws};
                }
   	if ($main::config_parms{weather_uom_rain} eq 'mm') {
      		$$wptr{RainTotal} = $$wptr{RainTotal_ws};
      		$$wptr{RainYest} = $$wptr{RainYest_ws};
    		}
    	if ($main::config_parms{weather_uom_rainrate} eq 'mm/hr') {
      		$$wptr{RainRate} = $$wptr{RainRate_ws};
    		}
    }
}

sub wx_temp2 {
    my ($n1, $n2) = @_;
    my $temp   =  sprintf('%x%02x', 0x07 & $n2, $n1);
    substr($temp, 2, 0) = '.';
    $temp *= -1 if 0x80 & $n2;
    $temp = &main::convert_c2f($temp);
    return $temp;
}
#=============================================================================
# DECODE DATA TYPE RAIN GAUGE
# Byte	Nibble	Bit	Meaning
#  0	01		Rain guage packet
#  1    xB			Unknown
#  1	Bx	 4	Rate over
#  1	Bx	 5	Total over
#  1	Bx	 6	Low batt.
#  1	Bx	 7	Yesterday over
#  2	DD		Rain rate, bc of 0<abc<999 mm/hr
#  3	xD		Rain rate, a of 0<abc<999 mm/hr
#  3	Dx		Rain Total, e of 0<abcd.e<9999.9 mm
#  4	DD		Rain Total, cd of 0<abcd.e<9999.9 mm
#  5	DD		Rain Total, ab of 0<abcd.e<9999.9 mm
#  6	DD		Rain Yesterday, cd of 0<abcd<9999 mm
#  7	DD		Rain Yesterday, ab of 0<abcd<9999 mm
#  8	DD		Total start date minute
#  9	DD		Total start date hour
#  10   DD		Total start date day
#  11   DD		Total start date month
#  12   DD		Total start date year
#=============================================================================
sub wx_rain {
    my ($wptr, $debug, @data) = @_;

    unless ($skip{RainRateOver}) {
	$$wptr{RainRateOver} = (($data[3] & 0x10)>>4) ? 1 : 0;
    }
    unless ($skip{RainTotalOver}) {
	$$wptr{RainTotalOver} = (($data[3] & 0x20)>>5) ? 1 : 0;
    }
    unless ($skip{BatRain}) {
	$$wptr{BatRain} = (($data[3] & 0x40)>>6) ? 0 : 1;
    }
    unless ($skip{RainYestOver}) {
	$$wptr{RainYestOver} = (($data[3] & 0x80)>>7) ? 1 : 0;
    }
    unless ($skip{RainRate}) {
	$$wptr{RainRate_ws}=sprintf('%u', 0x0f & $data[5])*100 + sprintf('%u', (0xf0 & $data[4])>>4)*10
				+ sprintf('%u', 0x0f & $data[4]);
    	# mm/h unit by default
    	$$wptr{RainRate} = $$wptr{RainRate_ws};
    	# Convert mm/h to in/h
    	$$wptr{RainRate}=sprintf("%.2f",$$wptr{RainRate_ws}*0.0393700787402);
    }
    unless ($skip{RainTotal}) {
	$$wptr{RainTotal_ws}=sprintf('%u', (0xf0 & $data[7])>>4)*1000 + sprintf('%u', 0x0f & $data[7])*100
			     + sprintf('%u', (0xf0 & $data[6])>>4)*10 + sprintf('%u', 0x0f & $data[6])
			     + sprintf('%u', (0xf0 & $data[5])>>4)*0.1;

    	# mm unit by default
    	$$wptr{RainTotal} = $$wptr{RainTotal_ws};
    	# Convert mm to in
    	$$wptr{RainTotal}=sprintf("%.2f",$$wptr{RainTotal_ws}*0.0393700787402);
    }
    unless ($skip{RainYest}) {
    	$$wptr{RainYest_ws} = sprintf('%u', (0xf0 & $data[9])>>4)*1000 + sprintf('%u', 0x0f & $data[9])*100
			      + sprintf('%u', (0xf0 & $data[8])>>4)*10 + sprintf('%u', 0x0f & $data[8]);
    	# mm unit by default
    	$$wptr{RainYest} = $$wptr{RainYest_ws};
    	# Convert mm to in
    	$$wptr{RainYest}=sprintf("%.2f",$$wptr{RainYest_ws}*0.0393700787402);
    }
    unless ($skip{RainTotalStartDate}) {
	$$wptr{RainTotalStartDate}=sprintf("%02x%02x%02x%02x%02x",$data[14],$data[13],$data[12],$data[11],$data[10]);
    }

    # Maybe better to put in .._monitor_.. script
    #$$wptr{SummaryRain} = sprintf("Rain Recent/Total: %3.1f / %4.1f  Barom: %4d",
    #                              $$wptr{RainYest}, $$wptr{RainTotal}, $$wptr{Barom});

    print "** RAIN GAUGE : $main::Time_Date\n" if $debug;
    print "       BatRain         ($$wptr{BatRain})\n" if $debug;
    print "       RainRateOver    ($$wptr{RainRateOver})\n" if $debug;
    print "       RainTotalOver   ($$wptr{RainTotalOver})\n" if $debug;
    print "       YesterdayOver   ($$wptr{RainYestOver})\n" if $debug;
    print "       RainRate        ($$wptr{RainRate_ws} mm/h) ($$wptr{RainRate} in/hr)\n" if $debug;
    print "       RainTotal       ($$wptr{RainTotal_ws} mm) ($$wptr{RainTotal} in)\n" if $debug;
    print "       RainYest        ($$wptr{RainYest_ws} mm) ($$wptr{RainYest} in)\n" if $debug;
    print "       RainTotalStartDate ($$wptr{RainTotalStartDate})\n" if $debug;
}
#=============================================================================
# DECODE DATA TYPE ANEMOMETER
# Byte	Nibble	Bit	Meaning
#  0	00		Anemometer data packet
#  1    xB		Unknown
#  1	Bx	 4	gust over
#  1    Bx	 5	average over
#  1    Bx	 6	low batt
#  1    Bx	 7	Unknown
#  2	DD		Gust direction, bc of 0<abc<359 degrees
#  3	xD		Gust direction, a  of 0<abc<359 degrees
#  3	Dx		Gust speed, c  of 0<ab.c<56 m/s
#  4	DD		Gust speed, ab of 0<ab.c<56 m/s
#  5	DD		Average speed, bc  of 0<ab.c<56 m/s
#  6	xD		Average speed, a of 0<ab.c<56 m/s
#  6	Bx	4	Unknown
#  6	Bx	5	Chill no data
#  6	Bx	6	Chill over
#  6	Bx	7	Sign of wind chill, 1 = negative
#  7	DD		Wind chill
#=============================================================================
sub wx_wind {
    my ($wptr, $debug, @data) = @_;

    unless ($skip{WindGustOver}) {
	$$wptr{WindGustOver} = (($data[3] & 0x10)>>4) ? 1 : 0;
    }
    unless ($skip{WindAvgOver}) {
	$$wptr{WindAvgOver} = (($data[3] & 0x20)>>5) ? 1 : 0;
    }
    unless ($skip{BatWind}) {
	$$wptr{BatWind} = (($data[3] & 0x40)>>6) ? 0 : 1;
    }
    unless ($skip{WindGustSpeed}) {
        $$wptr{WindGustSpeed_ws}=sprintf('%u',(0xf0 & $data[6])>>4)*10 + sprintf('%u',0x0f & $data[6])
				+ sprintf('%u',(0xf0 & $data[5])>>4)*0.1;
	# m/s unit by default
        $$wptr{WindGustSpeed}=$$wptr{WindGustSpeed_ws};
	# Convert m/s to mph
        $$wptr{WindGustSpeed}=sprintf("%.1f",$$wptr{WindGustSpeed_ws}*2.236932);

        $$wptr{WindGustDir}=sprintf('%u', 0x0f & $data[5])*100 + sprintf('%u', (0xf0 & $data[4])>>4)*10
	 	 		+ sprintf('%u', 0x0f & $data[4]);
    }
    unless ($skip{WindAvgSpeed}) {
        $$wptr{WindAvgSpeed_ws}=sprintf('%u', 0x0f & $data[8])*10 + sprintf('%u', (0xf0 & $data[7])>>4)
	 	 		+ sprintf('%u', 0x0f & $data[7])*0.1;
	# m/s unit by default
        $$wptr{WindAvgSpeed}=$$wptr{WindAvgSpeed_ws};
	# Convert m/s to mph
        $$wptr{WindAvgSpeed}=sprintf("%.1f",$$wptr{WindAvgSpeed_ws}*2.236932);
    }
    unless ($skip{WindChill}) {
        $$wptr{WindChill_ws} = sprintf('%x', $data[9]);
        $$wptr{WindChill_ws} *= -1 if 0x80 & $data[8];
	# C unit by default
        $$wptr{WindChill} = $$wptr{WindChill_ws};
	# Convert C to F
        $$wptr{WindChill} = &main::convert_c2f($$wptr{WindChill_ws});

        $$wptr{WindChillNoData} = (0x20 & $data[8])?1:0;
        $$wptr{WindChillOver} = (0x40 & $data[8])?1:0;
    }
    # Maybe better to deplace this in ".._monitor_.." script because problem with french langage
    #$$wptr{SummaryWind} = sprintf("Wind avg/gust:%3d /%3d  from the %s",
    #        $$wptr{WindAvgSpeed}, $$wptr{WindGustSpeed}, &main::convert_direction($$wptr{WindAvgDir}));

    print "** ANEMOMETER : $main::Time_Date\n" if $debug;
    print "       BatWind         ($$wptr{BatWind})\n" if $debug;
    print "       WindGustOver    ($$wptr{WindGustOver})\n" if $debug;
    print "       WindAvgOver     ($$wptr{WindAvgOver})\n" if $debug;
    print "       WindGustSpeed   ($$wptr{WindGustSpeed_ws} m/s) ($$wptr{WindGustSpeed} mph)\n" if $debug;
    print "       WindGustDir     ($$wptr{WindGustDir})\n" if $debug;
    print "       WindAvgSpeed    ($$wptr{WindAvgSpeed_ws} m/s) ($$wptr{WindAvgSpeed} mph)\n"  if $debug;
    print "       WindChill       ($$wptr{WindChill_ws} C) ($$wptr{WindChill} F)\n" if $debug;
    print "       WindChillNoData ($$wptr{WindChillNoData})\n" if $debug;
    print "       WindChillOver   ($$wptr{WindChillOver})\n" if $debug;
}
#=============================================================================
# DECODE DATA TYPE CLOCK
# This hits once an hour or when new RF clock time is being received.
# Byte	Nibble	Bit	Meaning
#  0	0f	 	Sequence number packet
#  1	xB	  	Date 1 digit minute
#  1	Bx	 4	Date 10 digit minute
#  1	Bx	 5	Date 10 digit minute
#  1	Bx	 6	Date 10 digit minute
#  1	Bx	 7	Batt. low
#  2	DD	  	Date hour
#  3	DD	  	Date Day
#  4	DD	  	Date Month
#  5	DD	  	Date Year
#=============================================================================
sub wx_time {
    my ($wptr, $debug, @data) = @_;

    #$$wptr{BatMain} = "Please check" if 0x80 & @data[3];
    $$wptr{BatMain} = (($data[3] & 0x80)>>7) ? 0 : 1;

    $$wptr{DateMain}=sprintf("%x%x%x%x%u%u",$data[7],$data[6],$data[5],$data[4],
	    	($data[3] & 0x70)>>4, $data[3] & 0x0F) if $debug;

    print "** MAIN UNIT - CLOCK : $main::Time_Date\n" if $debug;
    print "       BatMain         ($$wptr{BatMain})\n" if $debug;
    print "       DateMain        ($$wptr{DateMain})\n" if $debug;
}
#=============================================================================
# BARO-THERMO-HYGROMETER
#Byte	Nibble	Bit	Meaning
# 0	06	        Device 5=BTH, 6=EXTBTH
# 1	xB		Unknown
# 1	Bx	5	Dew under : 1=under, 0=normal
# 1	Bx	6	Battery status. Higher value == lower battery volt
# 2	DD		Temp, bc of eab.c Celsius
# 3	xD		Temp, a of eab.c Celsius
# 3	Dx	4,5	Temp, e of eab.c Celcius
# 3	Bx	6	Over/under
# 3	Bx	7	Sign of outside temp, 1 = negative
# 4	DD		Relative humidity, ab of ab percent
# 5	DD		Dew point, ab of ab Celsius
# 6	HH		Baro pressure, convert to decimal and
# 			add 600mb for device 6
# device 6
# 7	xB		Encoded 'tendency' 0x0c=clear 0x06=partly cloudy
#			0x02=cloudy 0x03=rain
# 8	DD		Sea level reference, cd of <abc.d>.
# 9	DD		Sea level reference, ab of <abc.d>. Add this to raw
#			bp from byte 6 to get sea level pressure.
#=============================================================================
sub wx_inside {
my $xb = "";
my ($wptr, $debug, @data) = @_;
my %eval = (0xc0 => "Sunny",
            0x60 => "Partly Cloudy",
            0x30 => "Rain",
            0x20 => "Cloudy",
            );

$$wptr{BatIndoor} = (($data[3] & 0x40)>>6) ? 0 : 1;

unless ($skip{TempIndoor}) {
        $$wptr{TempIndoor_ws}=sprintf('%u',(0x0f & $data[4]))*0.1 + sprintf('%u',(0xf0 & $data[4])>>4)*1
				+ sprintf('%u',(0x0f & $data[5]))*10 + sprintf('%u',(0x30 & $data[5])>>4)*100;
        $$wptr{TempIndoor_ws} *= -1 if 0x80 & $data[5];
	# C unit by default
        $$wptr{TempIndoor} = $$wptr{TempIndoor_ws};
	# Convert C to F
	$$wptr{TempIndoor} = &main::convert_c2f($$wptr{TempIndoor_ws});
	#Over/Under
	$$wptr{TempIndoorOverUnder} = ((($data[5] & 0x40)>>6)?1:0)*((0x80 & $data[5])?-1:1);
    }
$$wptr{DewIndoorUnder} = ($data[3] & 0x10)>>4;

unless ($skip{HumidIndoor}) {
      $$wptr{HumidIndoor}=sprintf('%u',(0x0f & $data[6]))*1 + sprintf('%u',(0xf0 & $data[6])>>4)*10;
}
unless ($skip{DewIndoor}) {
      $$wptr{DewIndoor_ws}=sprintf('%u',(0x0f & $data[7]))*1 + sprintf('%u',(0xf0 & $data[7])>>4)*10;
	# C unit by default
        $$wptr{DewIndoor} = $$wptr{DewIndoor_ws};
	# Convert C to F
	$$wptr{DewIndoor} = &main::convert_c2f($$wptr{DewIndoor_ws});
}

$$wptr{WxTendency} = &wx_f968;

unless ($skip{Barom}) {
   $xb = &wx_b968;
   $$wptr{Barom_ws} = sprintf('%.2f',($xb + 600));
   # mb unit by default
   $$wptr{Barom} = $$wptr{Barom_ws};
   # Convert mb to in
   $$wptr{Barom} = sprintf('%.2f', $$wptr{Barom_ws} * .0295301);

   # $$wptr{BaromSea_ws} = $xb + sprintf('%x%x',$data[12],$data[11]);
   # mb unit by default
   # $$wptr{BaromSea} = $$wptr{BaromSea_ws};
   # Calculate pressure sea level
   $$wptr{BaromSea_ws} = $$wptr{Barom_ws} + ($main::config_parms{altitude} / ($main::config_parms{ratio_sea_baro} * 3.2808399))
     if $main::config_parms{ratio_sea_baro};
   # Convert mb to in
   $$wptr{BaromSea} = sprintf('%.2f',$$wptr{BaromSea_ws} * .0295301);
   }

print "** BARO-THERMO-HYGROMETER : $main::Time_Date\n" if $debug;
print "       Device type     ($data[2])\n" if $debug;
print "       BatIndoor       ($$wptr{BatIndoor})\n" if $debug;
print "       TempIndoor      ($$wptr{TempIndoor_ws} C) ($$wptr{TempIndoor} F)\n" if $debug;
print "       TempIndoorOverUnder ($$wptr{TempIndoorOverUnder})\n" if $debug;
print "       HumidIndoor     ($$wptr{HumidIndoor})\n" if $debug;
print "       DewIndoor       ($$wptr{DewIndoor_ws} C) ($$wptr{DewIndoor} F)\n" if $debug;
print "       DewIndoorUnder  ($$wptr{DewIndoorUnder})\n" if $debug;
print "       WxTendency      ($$wptr{WxTendency})\n" if $debug;
print "       Barom           ($$wptr{Barom_ws} mb) ($$wptr{Barom} in)\n" if $debug;
print "       BaromSea        ($$wptr{BaromSea_ws} mb) ($$wptr{BaromSea} in)\n" if $debug;
}
#=============================================================================
# THERMO HYGRO THERMO-HYGROMETER (OUTSIDE)
# Byte	Nibble	Bit	Meaning
#  0	02		temp/humidity data
#  1	xB		Unknown
#  1	Bx	5	Dew under : 1=under, 0=normal
#  1	Bx	6	Battery status. Higher value == lower battery volt
#  2	DD		Temp, bc of eab.c Celsius
#  3	xD		Temp, a of eab.c Celsius
#  3	Dx	4,5	Temp, e of eab.c Celcius
#  3	Bx	6	Over/under
#  3	Bx	7	Sign of outside temp, 1 = negative
#  4	DD		Relative humidity, ab of ab percent
#  5	DD		Dew point, ab of ab Celsius
#=============================================================================
sub wx_outside {
my ($wptr, $debug, @data) = @_;

$$wptr{BatOutdoor} = (($data[3] & 0x40)>>6) ? 0 : 1;

unless ($skip{TempOutdoor}) {
        $$wptr{TempOutdoor_ws}=sprintf('%u',(0x0f & $data[4]))*0.1 + sprintf('%u',(0xf0 & $data[4])>>4)*1
				+ sprintf('%u',(0x0f & $data[5]))*10 + sprintf('%u',(0x30 & $data[5])>>4)*100;
        $$wptr{TempOutdoor_ws} *= -1 if 0x80 & $data[5];
	# C unit by default
        $$wptr{TempOutdoor} = $$wptr{TempOutdoor_ws};
	# Convert C to F
	$$wptr{TempOutdoor} = &main::convert_c2f($$wptr{TempOutdoor_ws});
	#Over/Under
	$$wptr{TempOutdoorOverUnder} = ((($data[5] & 0x40)>>6)?1:0)*((0x80 & $data[5])?-1:1);
    }
$$wptr{DewOutdoorUnder} = ($data[3] & 0x10)>>4;

unless ($skip{HumidOutdoor}) {
      $$wptr{HumidOutdoor}=sprintf('%u',(0x0f & $data[6]))*1 + sprintf('%u',(0xf0 & $data[6])>>4)*10;
}
unless ($skip{DewOutdoor}) {
      $$wptr{DewOutdoor_ws}=sprintf('%u',(0x0f & $data[7]))*1 + sprintf('%u',(0xf0 & $data[7])>>4)*10;
	# C unit by default
        $$wptr{DewOutdoor} = $$wptr{DewOutdoor_ws};
	# Convert C to F
	$$wptr{DewOutdoor} = &main::convert_c2f($$wptr{DewOutdoor_ws});
}
print "** THERMO-HYGROMETER : $main::Time_Date\n" if $debug;
print "       BatOutdoor       ($$wptr{BatOutdoor})\n" if $debug;
print "       TempOutdoor      ($$wptr{TempOutdoor_ws} C) ($$wptr{TempOutdoor} F)\n" if $debug;
print "       TempOutdoorOverUnder ($$wptr{TempOutdoorOverUnder})\n" if $debug;
print "       HumidOutdoor     ($$wptr{HumidOutdoor})\n" if $debug;
print "       DewOutdoor       ($$wptr{DewOutdoor_ws} C) ($$wptr{DewOutdoor} F)\n" if $debug;
print "       DewOutdoorUnder  ($$wptr{DewOutdoorUnder})\n" if $debug;

}
#=============================================================================
# THERMO HYGRO EXTRA SENSOR
# OR
# THERMO ONLY EXTRA SENSOR
# This unit can handle up to 3 extra sensors.
# Byte	Nibble	Bit	Meaning
#  0	02		temp/humidity data
#  1	xB		Sensor number bit encoded, 4=channel 3, 2=channel 2,
# 			1=channel 1
#  1	Bx	5	Dew under : 1=under, 0=normal
#  1	Bx	6	Battery status. Higher value == lower battery volt
#  2	DD		Temp, bc of eab.c Celsius
#  3	xD		Temp, a of eab.c Celsius
#  3	Dx	4,5	Temp, e of eab.c Celcius
#  3	Bx	6	Over/under
#  3	Bx	7	Sign of temp, 1 = negative
#  4	DD		Relative humidity, ab of ab percent
#  5	DD		Dew point, ab of ab Celsius
#=============================================================================
sub wx_spare {
my ($wptr, $debug, @data, $copy) = @_;

$$wptr{"ChannelSpare"} = ($data[3] & 0x0F)==4 ? 3 : ($data[3] & 0x0F);
$copy = $$wptr{"ChannelSpare"};

$$wptr{"BatSpare$copy"} = (($data[3] & 0x40)>>6) ? 0 : 1;

unless ($skip{"TempSpare$copy"}) {
        $$wptr{"TempSpare$copy". "_ws"}=sprintf('%u',(0x0f & $data[4]))*0.1 + sprintf('%u',(0xf0 & $data[4])>>4)*1
				+ sprintf('%u',(0x0f & $data[5]))*10 + sprintf('%u',(0x30 & $data[5])>>4)*100;
        $$wptr{"TempSpare$copy"."_ws"} *= -1 if 0x80 & $data[5];
	# C unit by default
        $$wptr{"TempSpare$copy"} = $$wptr{"TempSpare$copy"."_ws"};
	# Convert C to F
	$$wptr{"TempSpare$copy"} = &main::convert_c2f($$wptr{"TempSpare$copy"."_ws"});

	#Over/Under
	$$wptr{"TempSpareOverUnder$copy"} = ((($data[5] & 0x40)>>6)?1:0)*((0x80 & $data[5])?-1:1);
    }

# Get Dew & Humid if thermo-hygro
if ($data[2] == 2) {
   $$wptr{"DewSpareUnder$copy"} = ($data[3] & 0x10)>>4;

   unless ($skip{"HumidSpare$copy"}) {
        $$wptr{"HumidSpare$copy"}=sprintf('%u',(0x0f & $data[6]))*1 + sprintf('%u',(0xf0 & $data[6])>>4)*10;
   }
   unless ($skip{"DewSpare$copy"}) {
        $$wptr{"DewSpare$copy"."_ws"}=sprintf('%u',(0x0f & $data[7]))*1 + sprintf('%u',(0xf0 & $data[7])>>4)*10;
	# C unit by default
        $$wptr{"DewSpare$copy"} = $$wptr{"DewSpare$copy"."_ws"};
	# Convert C to F
	$$wptr{"DewSpare$copy"} = &main::convert_c2f($$wptr{"DewSpare$copy"."_ws"});
   }
 }
print "** EXTRA THERMO(ONLY/HYGROMETER) #$copy : $main::Time_Date\n" if $debug;
print "       Device type     ($data[2])\n" if $debug;
print "       ChannelSpare    ($$wptr{ChannelSpare})\n" if $debug;
print "       BatSpare$copy       (".$$wptr{"BatSpare$copy"}.")\n" if $debug;
print "       TempSpare$copy      (" . $$wptr{"TempSpare$copy"."_ws"} . " C) (" . $$wptr{"TempSpare$copy"} . " F)\n" if $debug;
print "       TempSpareOverUnder$copy (".$$wptr{"TempSpareOverUnder$copy"}.")\n" if $debug;
print "       HumidSpare$copy     (".$$wptr{"HumidSpare$copy"}.")\n" if $debug;
print "       DewSpare$copy       (" . $$wptr{"DewSpare$copy"."_ws"} . " C) (" . $$wptr{"DewSpare$copy"} . " F)\n" if $debug;
print "       DewSpareUnder$copy  (".$$wptr{"DewSpareUnder$copy"}.")\n" if $debug;
}
#=============================================================================
# DECODE DATA TYPE MINUTE
# not really sure what a "sequence" is but here is where it is handled -
# once a minute. Important thing here is this reports on the main unit
# battery which is either shown as good or not.
# Byte	Nibble	Bit	Meaning
#  0	0e		Sequence number packet
#  1	xB	  	Date 1 digit minute
#  1	Bx	 4	Date 10 digit minute
#  1	Bx	 5	Date 10 digit minute
#  1	Bx	 6	Date 10 digit minute
#  1	Bx	 7	Batt. low
#=============================================================================
sub wx_seq {
    my ($wptr, $debug, @data) = @_;

    $$wptr{BatMain} = (($data[3] & 0x80)>>7) ? 0 : 1;
    $$wptr{MinuteMain}=sprintf("%u%u",($data[3] & 0x70)>>4,$data[3] & 0x0F) if $debug;

    print "** MAIN UNIT - MINUTE : $main::Time_Date\n" if $debug;
    print "       BatMain         ($$wptr{BatMain})\n" if $debug;
    print "       MinuteMain      ($$wptr{MinuteMain})\n" if $debug;
}

# barometer processed
sub wx_b968{
my (@data) = @_;
my $b968 = $data[10];
my $b968h = 0x03 & $data[11];
$b968h = sprintf('%x%x',$b968h,$b968);
$b968h = hex($b968h);
$b968h = $b968h;
return $b968h;
}

sub wx_f968 {
my (@data) = @_;
my $f968 = $data[11];
my %eval = (0xc0 => "Sunny",
            0x60 => "Partly Cloudy",
            0x30 => "Rain",
            0x20 => "Cloudy",
            );
$f968 &= 0xf0;
$f968 = $eval{( 0xf0 & $f968)};
return $f968;
}

# 2001/11/18 v1.0 of Weather_wmr968.pm based on Bruce's Weather_wx200.pm
#
# $Log$
# Revision 1.5  2005/01/23 23:21:45  winter
# *** empty log message ***
#
# Revision 1.4  2004/02/01 19:24:35  winter
#  - 2.87 release
#
# Revision 1.3  2003/02/08 05:29:24  winter
#  - 2.78 release
#
# Revision 1.2  2002/08/22 04:33:20  winter
# - 2.70 release
#
# Revision 1.1  2001/12/16 21:48:41  winter
# - 2.62 release
#
# Revision 1.5  2001/09/23 19:28:11  winter
# - 2.59 release
#
# Revision 1.4  2001/08/12 04:02:58  winter
# - 2.57 update
#
#
