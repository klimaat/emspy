#!/usr/bin/perl
#===============================================================================
#
#         FILE:  Pstart.pm
#
#  DESCRIPTION:  Contains utilities specific to the ems_prep routine.
#                At least that's the plan
#
#       AUTHOR:  Robert Rozumalski - NWS
#      VERSION:  12.0
#      CREATED:  01/01/2012 06:31:20 AM
#     REVISION:  ---
#===============================================================================
#
package Pstart;
require 5.8.0;
use strict;
use warnings;
use English;
use vars qw (%EMSprep $mesg);

use EMS_love;
use EMS_utils;
use EMS_time;
use EMS_style;
use EMS_conf;


sub initialize {
#----------------------------------------------------------------------------------
#  This routine reads the prep_global.conf file  to initialize
#  some of the necessary values used by ems_prep.pl.
#----------------------------------------------------------------------------------
#
use Cwd;

    %EMSprep = %Pmain::EMSprep;

    #  Make sure that the routine is being run  from an appropriate domain directory.
    #  
    $ENV{EMS_RUN} = cwd();

    $EMSprep{UNGRIB} = "$ENV{EMS_BIN}/ungrib";
    $EMSprep{METGRID}= "$ENV{EMS_BIN}/metgrid";

    $EMSprep{GRIBDIR}= "$ENV{EMS_RUN}/grib";
    $EMSprep{CONF}   = "$ENV{EMS_RUN}/conf/ems_prep";
    $EMSprep{STATIC} = "$ENV{EMS_RUN}/static";
    $EMSprep{WPSPRD} = "$ENV{EMS_RUN}/wpsprd";
    $EMSprep{LOG}    = "$ENV{EMS_RUN}/log";
    $EMSprep{WPSNL}  = 'namelist.wps';

    unless (-d $EMSprep{STATIC} and -s "$EMSprep{STATIC}/$EMSprep{WPSNL}") {

        if (-d $EMSprep{STATIC}) {

            $mesg = "It appears that you are not running $ENV{EMSEXE} from a valid domain directory as the ".
                    "static/namelist.wps file is missing.  Perhaps something went horribly wrong ".
                    "during the localization process?";

        } else {

            $mesg = "It appears that you are not running $ENV{EMSEXE} from one of the domains under ".
                    "$ENV{EMS_HOME}/runs or possibly something went horribly wrong during the ".
                    "localization process. You must run $ENV{EMSEXE} from one domain directories; ".
                    "otherwise, bad stuff will happen, such as this run-on message again.";
        }
        &EMS_love::died(1,$mesg); return ();
    }


    #  Get the default values from the global configuration file (prep_global.conf)
    #  located beneath the wrfems/conf/ems_prep directory.
    #
    my $file = "$ENV{EMS_CONF}/ems_prep/prep_global.conf";
    unless (-s $file) {&EMS_love::died(1,"Global configuration is missing\n\n  $file"); return ();}

    
    #  Read the file into a temporary hash
    #
    my %hashm = &EMS_conf::readConf($file);


    #  Handle the TIMEOUT setting by placing it into the EMSprep hash
    #
    if (defined $hashm{TIMEOUT}) { $EMSprep{TIMEOUT} = $hashm{TIMEOUT}; delete  $hashm{TIMEOUT}; }
    $EMSprep{TIMEOUT} = 299 unless (defined $EMSprep{TIMEOUT} and $EMSprep{TIMEOUT} or $EMSprep{TIMEOUT} >= 0);


    #  Now populate the %EMSprep hash with the contents of the configuration file
    #
    for my $opt (keys %hashm) {$EMSprep{HKEYS}{uc $opt} = $hashm{$opt} if defined $hashm{$opt};}


    #  Get a list of all available data sets from the wrfems/conf/grib_info directory
    #
    $EMSprep{GRIBCONF} = "$ENV{EMS_CONF}/grib_info";
    unless (-d $EMSprep{GRIBCONF}) {&EMS_love::died(1,"A message from your personal EMS:","The grib_info directory ($EMSprep{GRIBCONF}) is missing or something."); return ();}

   
    opendir DIR => $EMSprep{GRIBCONF};
    @{$EMSprep{DSETS}} = grep /_gribinfo\.conf/ | s/_gribinfo\.conf//g, readdir DIR;


    #  Read in the master WPS namelist. 
    #  The information will be contained in a hash of a hash within a hash. Messy
    #
    %{$EMSprep{MASTERNL}} = &EMS_conf::nl2hash("$EMSprep{STATIC}/$EMSprep{WPSNL}");


    #  Define the core being used
    #
    ($EMSprep{CORE} = uc $EMSprep{MASTERNL}{SHARE}{wrf_core}[0]) =~ s/'//g;

    
    #  Is this a global domain?
    #
    $EMSprep{GLOBAL} = ($EMSprep{MASTERNL}{GEOGRID}{map_proj}[0] =~ /lat-lon/i and ! defined $EMSprep{MASTERNL}{GEOGRID}{dx}) ? 1 : 0;


    @{$EMSprep{RN}} = qw (I. II. III. IV. V. VI. VII. VIII. IX. X. XI. XII.);
    @{$EMSprep{SM}} = ("Shazam", "Fabulous", "Fantastic", "Yatzee", "Bingo", "Dyn-o-mite", "Excellent", "Schwing", "Grrrrrrreat",
                       "3 Thumbs Up", "That's Hot", "It's in the hole");

return %EMSprep;
}



sub options {
#----------------------------------------------------------------------------------
#  The options routine parses the options passed to the ems_prep.pl program
#  from the command line. Simple enough.
#----------------------------------------------------------------------------------
#
use Cwd;
use Getopt::Long qw(:config pass_through);
use Time::Local;

    %EMSprep = %Pmain::EMSprep;

    my %Option;    # Contains the user-specified options used exclusively in user_opts

    #  Do an initial check of the options and flags to look for obvious problems
    #
    &Putils::checkArgs(@ARGV) or return ();

    GetOptions ( "help"           => sub {&Putils::helpPlease},
                 "clean!"         => \$Option{CLEAN},
                 "allclean"       => \$Option{ALLCLEAN},

                 #  General override of various directories
                 #
                 "gribdir=s"      => \$Option{GRIBDIR},

                 #  Data set options in the form of <data set>:<method>:<source>
                 #
                 "dset=s"         => \$Option{RDSET},        # Specify the initialization data set(s)
                 "sfc=s"          => \@{$Option{SFCS}},      # Specify the static surface data sets
                 "lsm=s"          => \@{$Option{LSMS}},      # Specify the land surface data sets
                 "noaltsst"       => \$Option{NOALTSST},     # Do not use the alternate method for determining water temperatures in the absence of data
                 "local"          => \$Option{NOMETH},       # Only check for initialization files in local directory
                 "nogcnv"         => \$Option{NOCNV},        # Do not convert grib files between 2 <-> 1 formats

                 "dsquery|query=s"=> sub {&Putils::datasetQuery(@_)}, 
                 "dsinfo=s"       => sub {&Putils::datasetQuery(@_)},
                 
                 "dslist"         => sub {&Putils::datasetList},    # list out data sets available for initialization

                 "noproc"         => \$Option{NOPROCESS},    #  Do not processes the grid files for model initialization
                 "domains=s"      => \$Option{DOMAIN},       #  Process initialization files for domains 1 ... --domains #
                 "hiresbc"        => \$Option{HIRESBC},      # Interpolate between BC file times to create hourly BC files.
                 "date=s"         => \$Option{RDATE},        # Specify the date of the files used for initialization
                 "cycle=s"        => \$Option{RCYCLE},       # Specify the cycle time to be used for initializtaion
                 "synchr|besthr=s" => \$Option{BESTHR},      # Match the surface data set hour with the closest cycle hour
                 "timevar=s"      => \$Option{TIMEVAR},      # Time Varying Static Surface fields
                 "length=i"       => \$Option{FLENGTH},      # Set the forecast length
                 "previous"       => \$Option{PREVIOUS},     # Use the previous cycle of the data set rather then the current one
                 "analysis:i"     => \$Option{ANAL},         # Use analyses for initial and boundary conditions
                 "nodelay"        => \$Option{NODELAY},      # Sets the DELAY to 0 hours
                 "nudge"          => \$Option{NUDGING},      # Process requested domains for 3D Analysis Nudging
                 "onlybndy:5"     => \$Option{BNDYROWS},     # Process only [ROWS] outer rows used for the lateral boundaries. Default is 5 rows

                 "benchmark"      => \$EMSprep{BM},          # Run the benchmark case

                 "timeout:299"    => \$Option{TIMEOUT},      # Timeout value to be used with mpich2 & metgrid

                 "nometgrid"      => \$Option{NOMETGRID},    # Do not run the metgrid routine specified. Exit before
                 "nodegrib"       => \$Option{NODEGRIB},     # Do not run the degrib routine specified. Exit before
                 "gribdel!"       => \$Option{GRIBDEL},      # Do (not) Delete the grib files after processing
                 "intrdel!"       => \$Option{INTRDEL},      # Do (not) delete the intermediate files after processing
                 "debug"          => \$Option{DEBUG},        # Print out informative messages about the data sets
                 "verbose:i"      => \$Option{VERBOSE});
    


    #  Test for silly combinations of options
    #
    my $silly;
       $silly = '--date  and --previous' if $Option{PREVIOUS} and $Option{RDATE};
       $silly = '--cycle and --previous' if $Option{PREVIOUS} and $Option{RCYCLE} and ! $Option{RCYCLE} =~ /CYCLE/i;

    if ($silly) {
        $mesg = "This is just silly!\n\nYou can't pass the $silly options together as ".
                "they may cause problems.\n\n".
                "Yes, the EMS, just like life, is unfair sometimes. OK, maybe more than ".
                "just sometimes but I don't make the rules. I just write the code.";
        &EMS_love::died(1,$mesg); return ();
    }


    #  Make sure the argument passed with --onlybndy is greater than or equal to 0; otherwise set to 0 (turn off).
    #
    $Option{BNDYROWS} = 0 unless defined $Option{BNDYROWS}  and $Option{BNDYROWS} > 0;
    $Option{BNDYROWS} = 0 if defined $Option{NUDGING} and $Option{NUDGING};  # Interior points are needed when nudging


    # allow for the passing of multiple --sfc and --lsm options
    #
    $Option{SFC} = join "," => @{$Option{SFCS}} if @{$Option{SFCS}};
    $Option{LSM} = join "," => @{$Option{LSMS}} if @{$Option{LSMS}};


    #  Set the level of verbosity for ems_post then send to ENV variable
    #
    $ENV{VERBOSE} = defined $Option{VERBOSE} ? $Option{VERBOSE} : $ENV{VERBOSE} ? $ENV{VERBOSE} : 3;


    #  If the use passes the --clean or --allclean flags then simply clean up the domain
    #  directory and exit. This is the same as running the ems_clean utility with the 
    #  --level 3 or --level 4 flags respectively.
    #
    &Putils::clean($ENV{EMS_RUN},3,1,1) if $Option{CLEAN};
    &Putils::clean($ENV{EMS_RUN},4,1,1) if $Option{ALLCLEAN};

    #  Each time ems_prep is run clean the domain directory to "--level 3" standards.
    #
    &Putils::clean($ENV{EMS_RUN},3,1,0);

  
    #  Make sure nudging is defined
    #
    $Option{NUDGING} = 0 unless $Option{NUDGING};

    #  Check the formatting of the --cycle option if passed
    #
    if (defined $Option{RCYCLE} and $Option{RCYCLE} =~ /^--/) {
        $mesg = "The --cycle option was passed with no arguments - ignoring";
        &EMS_style::emsprint(2,16,144,1,2,"Problem with --cycle Option",$mesg);
        undef $Option{RCYCLE};
    }
    $Option{RCYCLE} = "CYCLE$Option{RCYCLE}" if $Option{RCYCLE} and $Option{RCYCLE} =~ /^:/;

    #  Set the default as the most recent cycle
    #
    $Option{RCYCLE} = 'CYCLE' unless $Option{RCYCLE};

    #  If the RCYCLE option was passed then make sure formatting is correct
    #
    #
    for ($Option{RCYCLE}) {
        s/,|;/:/g; #  replace with colons
        my @list = split /:/ => $_;
        foreach (@list) {
            next unless $_;
            if (/\D/) {
                $_ = uc $_;
                s/S//g; # eliminate trailing "S"
                s/BCFREQ/FREQFH/g;
                unless (/[CYCLE|INITFH|FINLFH|FREQFH]/) {
                    $mesg = "Operator Error (Again)\n\nHey what's this argument to the --cycle option - $_? Only CYCLE|INITFH|FINLFH|FREQFH allowed.";
                    &EMS_love::died(1,$mesg); return ();
                }
            } else { #  all digits - want padded
                $_ = sprintf("%02d", $_);
            }
        }
        $Option{RCYCLE} = join ":", @list;
    }


    # Make sure --length was not passed with and characters
    #
    $Option{FLENGTH} =~ tr/[a-z][A-Z]//c if $Option{FLENGTH};


    #  Check if this is a benchmark case. If so, then override configurations.
    #
    $EMSprep{BM} = -e "$EMSprep{STATIC}/.benchmark" ? 1 : 0;
    if ($EMSprep{BM}) {
        # Set the case initialization information
        #
        $Option{VERBOSE} = 3;
        $Option{RDSET}   = "cfsr:none";
        $Option{NODELAY} = 1;
        $Option{INTRDEL} = 1;
        $Option{GRIBDEL} = 0;
        $Option{FLENGTH} = ($Option{FLENGTH} and $Option{FLENGTH} <= 24) ?  $Option{FLENGTH} : 24;
        $Option{RCYCLE}  = "18:00:24:06";
        $Option{RDATE}   = "20070818";
        $Option{DOMAIN}  = "2:6" if $Option{DOMAIN};

        my $c    = $EMSprep{CORE} =~ /nmm/i ? "NMM Core" : "ARW Core";
        $mesg = "You have chosen to run the 18-19 August 2007 EMS $c benchmark case. Absolutely fabulous!";
        &EMS_style::emsprint(0,6,114,1,2,$mesg);
    }


    #  Initialize the EMSprep hash with the option values
    #
    for my $opt (keys %Option) {$EMSprep{$opt} = $Option{$opt} if defined $Option{$opt};}


    #  Set the default for $EMSprep{INTRDEL} to delete files
    #
    $EMSprep{INTRDEL} = 1 unless defined $EMSprep{INTRDEL};
    $EMSprep{GRIBDEL} = 0 unless defined $EMSprep{GRIBDEL};


    #  Create the grib directory 
    #
    return () if &EMS_system::mkdir($EMSprep{GRIBDIR});

    # Check whether --dset was passed, which is mandatory
    #
    unless (defined $EMSprep{RDSET}) {&EMS_love::died(1,"Missing mandatory \"--dset\" option. Try the \"--help\" option for guidance."); return ();}


    #  If the user passed the --date flag then make sure the format is correct.
    #
    if ($EMSprep{RDATE}) {
        if (length($EMSprep{RDATE}) == 6) {
            $EMSprep{RDATE} = substr($EMSprep{RDATE},0,2) < 45 ? "20$EMSprep{RDATE}" : "19$EMSprep{RDATE}"; chomp $EMSprep{RDATE};
        } elsif (length($EMSprep{RDATE}) != 8) {
            $mesg = "Initialization Date Problem:\n\n".
                    "Invalid date of initialization data set ($EMSprep{RDATE}) < --date [YY]YYMMDD >";
            &EMS_love::died(1,$mesg); return ();
        }
    }


return %EMSprep;
}



sub configure {
#----------------------------------------------------------------------------------
#  The configure routine does much of the configuration for the ems_prep options
#----------------------------------------------------------------------------------
#
use Time::Local;


    %EMSprep = %Pmain::EMSprep;

    my %Info=();   # Hash to collect the simulation information

    #  This is a kludge for the condition that the user has not requested the terrain data set
    #  when using the NARR data
    #
    #if (grep (/narr/i, $EMSprep{RDSET}) ) {
    #    if ($EMSprep{SFC}) {
    #        $EMSprep{SFC} = "narrfixed,$EMSprep{SFC}" unless grep (/narrfixed/i, $EMSprep{SFC});
    #    } else {
    #        $EMSprep{SFC} = "narrfixed";
    #    }
    #}

    # Same thing for the NNRP (Reanalysis 1) data
    #
    if (grep (/nnrp/i, $EMSprep{RDSET}) ) {
        if ($EMSprep{LSM}) {
            $EMSprep{LSM} = "nnrp2d,$EMSprep{LSM}" unless grep (/nnrp2d/i, $EMSprep{LSM});
        } else {
            $EMSprep{LSM} = "nnrp2d";
            $mesg = "FYI - Including nnrp land surface data set (nnrp2d) with NNRP initialization.";
            &EMS_style::emsprint(1,6,108,0,2,$mesg);
        }
    }

    #  Begin parsing of the $EMSprep{RDSET} option, which contains the information on which data set
    #  to use for initialization, the method of acquisition, and the server.
    #
    my (@rdsets, @rdsfcs, @rdlsms) = ();
    @rdsets = split /%|,/ => $EMSprep{RDSET} if $EMSprep{RDSET};
    @rdsfcs = split /%|,/ => $EMSprep{SFC}   if $EMSprep{SFC}; $_ =~ s/ptiles/ptile/g foreach @rdsfcs;
    @rdlsms = split /%|,/ => $EMSprep{LSM}   if $EMSprep{LSM}; $_ =~ s/\"\'//g foreach @rdlsms; $_ =~ s/ptiles/ptile/g foreach @rdlsms;


    #  Reverse the order of the LSM data sets to that the list will be correctly specified
    #  in the metgrid namelist.  At this point @rdlsms should contain series of LMS data
    #  sets with fail-over options. The fail-over data sets will be handled below.
    #
    @rdlsms = reverse @rdlsms if @rdlsms;


    if (scalar(@rdsets) > 2) {
        $mesg = "HEY TROUBLE MAKER!\n\n".
                "You may specify a maximum of 2 different arguments for the initial and boundary conditions ".
                "with the \"--dsets\" option. So let us try it again. Oh ya, have a nice day!";
        &EMS_love::died(1,$mesg); return ();
    }


    if (scalar @rdsets  > 1 and !$EMSprep{FLENGTH}) {
        $mesg = "HELLO THERE!\n\n".
                "You must specify the forecast length, in hours, using the \"--length <hours>\" option if more ".
                "than one data set is requested.";
        &EMS_love::died(1,$mesg); return ();
    }


    #  Make sure ems_prep knows about the analysis flag
    #
    $EMSprep{ANAL} = 0 if defined $EMSprep{ANAL} and ! $EMSprep{ANAL};

    #  If the ruc hybrid analysis or forecast grid was requested as the lone data set
    #  for model initialization while NOT passing the --analysis flag, then include
    #  the missing ruc data set.  Note that both ruc13ha and ruc13hf should be requested
    #  as --dset ruc##ha%ruc##hf but take care of it here so the user is not bothered.
    #
    if ( (grep /^ruc.+a|^ruc.+f/i, @rdsets) and (scalar @rdsets == 1) and ! defined $EMSprep{ANAL} ) {
        if (grep /^ruc.+a/i, @rdsets) { #  Need to include forecast data set
            my $rds = $rdsets[0]; $rds =~ s/a$/f/g; push @rdsets => $rds;
            (my $mds = $EMSprep{RDSET}) =~ s/$rdsets[0]/$rds/g; $EMSprep{RDSET} = "$EMSprep{RDSET}\%$mds";
        } else {
            my $rds = $rdsets[0]; $rds =~ s/f$/a/g; unshift @rdsets => $rds;
            (my $mds = $EMSprep{RDSET}) =~ s/$rdsets[1]/$rds/g; $EMSprep{RDSET} = "${mds}\%$EMSprep{RDSET}";
        }
    }


    #  The RUC relies on it's skin temperature to serve as SSTs; however, some external LSM
    #  data sets such as LIS use a masked SKIN temperature. This causes major problems since
    #  the LIS skin usurps the RUC and therefore there will not be any SSTs.
    #
    #  The easy work-around is to output the RUC SKIN field as SSTs separately
    #
    if ($rdsets[0] =~ /^rap.+ha/i and $EMSprep{LSM} ) {
        (my $sstds = $rdsets[0]) =~ s/ha/sst/g;
        push @rdsfcs => $sstds;
    }

    unless (defined $EMSprep{ANAL}) {
        #  Pass the analysis flag for the Climate Forecast System Reanalysis (CFSR) data set
        #
        if ( (grep /^cfsr/i, @rdsets) and (scalar @rdsets == 1) ) {
            $mesg = "The use of CFSR data set requires that you include the \"--analysis\" ".
                    "flag.\nIncluding the flag for you this time.";
            &EMS_style::emsprint(6,6,96,0,2,"Hey, try using the --analysis flag next time",$mesg) unless $EMSprep{BM};
            $EMSprep{ANAL} = 0;
        }
    }


    #  If the user is requesting a nested simulation additional error checking must be done
    #  to ensure that the parent domain is also being requested and that the start time being
    #  requested is not earlier that the start of the parent domain.  Lot of ugly error checking.
    #
    #  It is assumed that each domain defined in the namelist.wps file is a child of a domain
    #  defined PREVIOUSLY in the list.
    #
    #  The format for the option is --domain <domain number>:<start time in hours after parent domain>
    #
    my @rdoms;
    if ($EMSprep{DOMAIN}) {

        #  Initially split the argument to the --domain option into a hash. Ignore requests for
        #  domains that lie outside the max number available as defined by max_dom.
        #
        my %nests = ();
        $nests{1} = 0;
        foreach (split /,|;/ => $EMSprep{DOMAIN}) {
            my ($dom, $hour) = split /:/ => $_, 2;
            next if $dom <= 1;
            unless ($dom <= $EMSprep{MASTERNL}{SHARE}{max_dom}[0]) {
                $mesg = "Domain $dom does not exist! Only 1 .. $EMSprep{MASTERNL}{SHARE}{max_dom}[0]";
                $mesg = "Domain $dom does not exist! Only Domain 1" if $EMSprep{MASTERNL}{SHARE}{max_dom}[0] == 1;
                &EMS_love::died(1,$mesg); return ();
            }
            $nests{$dom+=0} = $hour ? $hour : 0 if $dom > 1 and $dom <= $EMSprep{MASTERNL}{SHARE}{max_dom}[0];
            push @rdoms => $dom+=0;
        }
        @rdoms = sort {$a <=> $b} @rdoms; # save the requested domains

        #  Now we shall fill in the missing domains not specified and not a parent of the
        #  requested domains. Begin by getting the largest domain value.
        #
        my $max=1;
        foreach (keys %nests) {$max = $_ if $_ > $max;}

        for my $i (1 .. $max) {
            unless (defined $nests{$i} and $nests{$i} > $nests{$EMSprep{MASTERNL}{GEOGRID}{parent_id}[$i-1]}) {
                $nests{$i} = $nests{$EMSprep{MASTERNL}{GEOGRID}{parent_id}[$i-1]};
            }
            my $e_sn = $EMSprep{MASTERNL}{GEOGRID}{e_sn}[$i-1];
            my $e_we = $EMSprep{MASTERNL}{GEOGRID}{e_we}[$i-1];
            my $n_sn = $e_sn;
            my $n_we = $e_we;

            if ($EMSprep{CORE} =~ /nmm/i) {
                #  Here we are going to test the requirements for NMM nested domain dimensions
                #
                $n_sn = $n_sn + 1 if $n_sn % 2 == 1;
                if ($i > 1) {

                    $n_sn = $n_sn - 2 while ( (($n_sn-1)/3)/int(($n_sn-1)/3) > 1);
                    $n_we = $n_we - 1 while ( (($n_we-1)/3)/int(($n_we-1)/3) > 1);

                    if ($e_sn != $n_sn) {
                        my $err = int rand(1000);
                        $mesg = "The south-north grid dimension for domain $i does not meet the strict ".
                                "requirements clearly spelled out somewhere in the NMM Users Guide.\nChanging ".
                                "the south-north dimension from $e_sn to $n_sn. I really hope you don't mind.";
                        &EMS_style::emsprint(6,6,84,1,2,"EMS Inspirational Message #$err - Help Me, Help You",$mesg);
                        $e_sn = $n_sn;
                    }

                    if ($e_we != $n_we) {
                        my $err = int rand(1000);
                        $mesg = "The west-east grid dimension for domain $i does not meet the strict ".
                                "requirements clearly spelled out somewhere in the NMM Users Guide.\nChanging ".
                                "the west-east dimension from $e_we to $n_we. I really hope you don't mind.";
                        &EMS_style::emsprint(6,6,84,1,2,"EMS Inspirational Message #$err - Help Me, Help You",$mesg);
                        $e_we = $n_we;
                    }


                }
            }
            $EMSprep{MASTERNL}{GEOGRID}{e_sn}[$i-1] = $e_sn;
            $EMSprep{MASTERNL}{GEOGRID}{e_we}[$i-1] = $e_we;
            $Info{domains}{$i}{parent} = $EMSprep{MASTERNL}{GEOGRID}{parent_id}[$i-1];
        }
        %{$EMSprep{DOMAINS}} = %nests;
    }


    #  Make sure tat there is only a single entry for the ref I/J values.
    #
    @{$EMSprep{MASTERNL}{GEOGRID}{ref_y}} = ();
    @{$EMSprep{MASTERNL}{GEOGRID}{ref_x}} = ();
    $EMSprep{MASTERNL}{GEOGRID}{ref_y}[0] = $EMSprep{MASTERNL}{GEOGRID}{e_sn}[0]/2;
    $EMSprep{MASTERNL}{GEOGRID}{ref_x}[0] = $EMSprep{MASTERNL}{GEOGRID}{e_we}[0]/2;


    #  The lists of LMS data set and fail-over options must be broken up
    #  into a single array of data sets for the next section. This is
    #  only done to check the user's input.
    #
    my @lsmlist=();
    @lsmlist = (@lsmlist,split /\|/ => $_) foreach @rdlsms;


    #  Make sure that the user is requesting valid data sets. Need to look through all
    #  requested sets. The @{$EMSprep{DSETS}} list  holds the array of available data sets
    #  as determined from the *_gribinfo.conf.
    #
    my $n=0;
    my @ops = ();
    push @ops => '--dset' foreach @rdsets;
    push @ops => '--sfc'  foreach @rdsfcs;
    push @ops => '--lsm'  foreach @lsmlist;


    foreach (@rdsets, @rdsfcs, @lsmlist) {

        #  Replace ptiles -> ptile
        #
        s/ptiles/ptile/g;
        s/ptile//g if $EMSprep{GLOBAL}; #  No personal tiles for global data sets


        #  Split the data sets into those for initialization and boundary conditions
        #
        my ($dset,$method,$server,$loc) = split /:|;|,/,$_,4;

        unless ($dset) {
            $mesg = "Problem With --dset option\n\n".
                    "No data set was specified for $ops[$n] <data set>[:<method>:<source>] option. ".
                    "Use the \"--help\" option for more information.";
            &EMS_love::died(1,$mesg); return ();
        }

        #  Some special NARR and ECMWF love
        #
        if ($dset =~ /narr/i or $dset =~ /nnrp/i or $dset =~ /ecmwf/i) { 
            $EMSprep{ANAL} = (defined $EMSprep{ANAL}) ? $EMSprep{ANAL} : 0;
        }

        if ($dset =~ /laps/i and !$EMSprep{LSM}) {
            $mesg = "LAPS initialization Problem:\n\n".
                    "You must specify a land surface data set (--lsm <data set>[:<method>:<source>]) ".
                    "with LAPS initialization.";
            &EMS_love::died(1,$mesg); return ();
        }

        if ($dset =~ /^ruc.+pa/i and !$EMSprep{LSM}) {
            $mesg = "RUC initialization Problem:\n\n".
                    "You must specify a land surface data set (--lsm <data set>[:<method>:<source>]) ".
                    "with RUC isobaric data set initialization.";
            &EMS_love::died(1,$mesg); return ();
        }


        #  Urge users to consider MODIS with LIS data set
        #
        if ( ($dset eq 'lis' or $dset eq 'lisptile' ) and ($EMSprep{LSM} =~ /lis/i)) {

            opendir DIR => $EMSprep{STATIC};
            my $modis = 0;
            foreach (sort grep /\.d01\.nc$/ => readdir DIR) {$modis = (&EMS_files::readVarCDF("$EMSprep{STATIC}/$_",'MMINLU') =~ /MODIS/i) ? 1 : 0;}
            close DIR;

            unless ($modis) {
                $mesg = "I am taking this time away from your simulation stimulation to strongly urge you to consider ".
                        "using the MODIS land use categories with the LIS LSM data set.\n\nTo make the change, run:\n\n".
         
                        "  % ems_domain --localize --modis\n\n".

                        "prior to running ems_prep. You only need to do this step once, and trust me, we will both ".
                        "be better off for the change.";

                &EMS_style::emsprint(6,4,88,1,3,"Your Localization Disturbs Me",$mesg);
            }
        }


        unless (grep /^${dset}$/,@{$EMSprep{DSETS}}) {
            my $len = length $dset;
            $mesg = sprintf ("I don't know what you're thinking:\n\nData set $ops[$n] \"%${len}s\" is not a supported data set.",$dset);
            &EMS_love::died(1,$mesg); return ();
            &Putils::datasetList; 
        }

        if ($method) {
            unless ($method =~ /ftp|http|nfs|none/i) {
                $mesg = "What Method is This?\n\n".
                        "Invalid acquisition method requested ($method). Only ftp|http|nfs|nonfs|noftp|nohttp|none supported.";
                &EMS_love::died(1,$mesg);
                &Putils::datasetQuery($ENV{EMSEXE},$dset); return ();
            }
        }
        $n++;
    }


    #  The variable $nd is used to identify whether a particular data set will be
    #  used for model initial conditions ($nd = 2), boundary conditions ($nd = 3),
    #  or both ($nd = 1). This value is carried by the "useid" variable in the data
    #  set structure.
    #
    my $nd = 0;
    $nd++ if scalar @rdsets > 1;


    #  The lines below creates and populates the data structures used to define the
    #  user requested data sets.
    #
    @{$EMSprep{DSTRUCTS}}=();
    foreach my $rdset (@rdsets) {push @{$EMSprep{DSTRUCTS}} => &gribinfo($rdset,++$nd);}


    my $abcfreq=0;
    if (@rdsets > 1) {
        #  We need to get the BC update frequency before determining which cycle time
        #  to use for the model initialization data set.  No sense initializing a run
        #  at 17 UTC when your BC updates are every 3 hours.
        #

        #  The data set information is stored in a hash in semi-random order, thus we
        #  must first loop through the list to locate the BC struct. Then look through
        #  it again to get the IC cycles list and compare.
        #
        foreach my $data_info (@{$EMSprep{DSTRUCTS}}) {$abcfreq = $data_info->freqfh if $data_info->useid == 3; $abcfreq+=0;}

        foreach my $data_info (@{$EMSprep{DSTRUCTS}}) {
            if ($data_info->useid == 2) {  #  We have the IC structure
                my (@acycles,@bcycles)=();  #  Lists of acceptible and bad cycle times
                my @icycles = sort @{$data_info->cycles}; @{$data_info->cycles}=(); # Clear out cycle list and repopulate.
                foreach my $str (@icycles) {
                    my @list  = split /:/ => $str; #  Split the info and get the actual cycle hour
                    next unless defined $list[0];
                    my $cycle = $list[0]+=0;
                    #  Compare the cycle time of the IC data set to the available BC forecast frequency
                    #
                    $cycle % $abcfreq ? push @bcycles=>$cycle : push @acycles=> sprintf("%02d", $cycle);
                    push @{$data_info->cycles} => $str unless $cycle % $abcfreq;
                }
                my $str = join ', ' => @acycles;
                &EMS_style::emsprint(6,4,256,1,2,"Warning: Only allowing $str UTC $rdsets[0] cycle times with $rdsets[1] boundary conditions") if @bcycles;
                $abcfreq = 0 unless @bcycles;
            }
        }
    }


    
    # If this is a global simulation then we need to do some house keeping
    #
    if ($EMSprep{GLOBAL}) {
        my $dset  = $EMSprep{DSTRUCTS}[0]; @{$EMSprep{DSTRUCTS}}=();
        my $rdset = $rdsets[0]; @rdsets = ();
        push @{$EMSprep{DSTRUCTS}} => $dset;
        push @rdsets => $rdset;
    }


    #  Now for the surface and land surface data sets
    #
    my @sstructs=();
    my @lstructs=();
 
    foreach (@rdsfcs) {push @sstructs => &gribinfo($_,5);}
    foreach (@rdlsms) {push @lstructs => &gribinfo($_,4);}


    #**********************************************************************************#
    #  Begin loping through all the requested data sets. This step is messy due to the #
    #  inclusion of multiple data sets used for initial and boundary conditions.       #
    #**********************************************************************************#
    #

    #  Set date to current by default. Will override if --date option is passed.
    #
    my $yymmdd     = `date -u +%y%m%d`  ; chomp $yymmdd;
    my $yyyymmdd   = `date -u +%Y%m%d`  ; chomp $yyyymmdd;
    my $yyyymmddxx = `date -u +%Y%m%d%H`; chomp $yyyymmddxx;
    my $yyyymmddhh = $yyyymmddxx; # Temporarily
    my $yyyymmddcc;


    my $icvc;  # For keeping track of the vertical coordinates of the IC and BC data set
    my $bhi;   # Information that will be printed out after this section is completed
    my $rbcfreq; # for command-line defined BC freq

    foreach my $data_info (@{$EMSprep{DSTRUCTS}}) {

        my ($acycle, $iinitfh, $ifinlfh, $ifreqfh);

        $data_info->useid(2) if $EMSprep{GLOBAL};

        #  How is this particular data set to be used?  Options are:
        #
        $mesg = "Initial and Boundary Condition Data Set" if $data_info->useid == 1;
        $mesg = "Initial Condition Data Set"              if $data_info->useid == 2;
        $mesg = "Boundary Condition Data Set"             if $data_info->useid == 3;

        $mesg = "$mesg (w/nudging)" if $EMSprep{NUDGING};

        &EMS_style::emsprint(1,6,96,0,2,$mesg) if $EMSprep{DEBUG};


        #  Keep track of the data set vertical coordinate. Prior to WPS V3.1 you could not
        #  mix vertical coordinated but it appears that you can with V3.1.  This part of
        #  the code may be removed later but for now it is just deactivated.
        #
        $icvc = $data_info->vcoord if $data_info->useid == 2;
        if ($data_info->useid == 3 and $data_info->vcoord ne $icvc) {
            my $bcvc = $data_info->vcoord;
            $mesg = "The use of different vertical coordinate systems for initial ($icvc) ".
                    "and boundary conditions ($bcvc) is currently not supported in the WRF. ".
                    "This should be fixed in a future release if it makes you feel any better, ".
                    "which I'm sure it doesn't.";
#           &EMS_style::emsprint(6,6,92,0,2,"Mixed Vertical Coordinate ($icvc Vs. $bcvc)",$mesg);
#           return 1;
        }


        #  Make sure that the requested BC update frequency is greater than or equal to
        #  the maximum allowed value. If not then provide a warning and change the value
        #  of the requested BC update frequency.  Other consequences to follow.
        #
        if ($data_info->useid == 1 or $data_info->useid == 3) {
            my $bcf = $data_info->freqfh;  $bcf+=0;
            my $bcm = $data_info->maxfreq; $bcm+=0;
            if ($bcf < $bcm) {
                $mesg = "Your requested BC update frequency ($bcf) is greater then the maximum ".
                        "allowed value ($bcm) as defined by MAXUDFREQ in the <data set>_gribinfo.conf ".
                        "file. The MAXUDFREQ value will be used instead although something else ".
                        "may break.";
                &EMS_style::emsprint(6,6,92,1,3,"Boundary Condition Update Frequency Issue:",$mesg);
                $data_info->freqfh($data_info->maxfreq);
            } elsif ($bcf%$bcm) {
                $mesg = "The boundary condition update frequency ($bcf) must be an integer multiple of the ".
                        "value for MAXUDFREQ ($bcm) as defined in the <data set>_gribinfo.conf file. ".
                        "Hey, I don't make the laws I just enforce them.";
                &EMS_style::emsprint(6,6,92,1,3,"Boundary Condition Update Frequency Violation:",$mesg);
                return ();
            }
        }


        #  Just information storage. Nothing to see here
        #
        $Info{ids} = $data_info->dset unless $data_info->useid == 3;
        $Info{bds} = $data_info->dset unless $data_info->useid == 2;


        #  Override the default DELAY setting in the data set configuration file if --delay is passed
        #
        $data_info->delay(0) if $EMSprep{NODELAY};


        #  Make a list of (hourly) date/times from -24hr to the requested date/time of the
        #  00hr forecast.  The actual dates & times in the list are bounded by the most
        #  current data set available for the requested data set unless the used has passed
        #  the --date and/or --cycle flags, in which case those values control the entries
        #  in the list.
        #
        #  The $EMSprep{YYYYMMDDCC} contains the date/cycle time of the data set used for
        #  initial (and possibly boundary) conditions and should not be confused with the
        #  $EMSprep{RUN00H} variable that contains the 00 Hr of the simulation. These
        #  values are used elsewhere in the code.
        #
        my @pdates=();  # A list of 24 possible date/times.
        my $shr   =1;


        #  $sdate is the upper bound (most current) date/time to be used for a specified
        #  data set. The actual date/time in the list will be controlled by factors such
        #  as the date or cycle time passed by the user, the available cycle times of a
        #  data set, and the date cycle time of the initialization data set (BC data).
        #
        #  $yyyymmddxx holds the current machine date and time in UTC
        #  $yyyymmddhh holds the 00Hr date/time of the simulation and is initially
        #              set to $yyyymmddxx but will be updated when processing BC data
        #              set times.
        #  $yyyymmddcc holds the 00Hr date/time of the initialization data set
        #
        my $sdate = $EMSprep{RDATE} ? "$EMSprep{RDATE}23" : $yyyymmddhh;
           $sdate = $yyyymmddcc if $yyyymmddcc; #  $yyyymmddcc is assigned after the first loop so
                                                #  should be available for processing BC data sets
                                                #  $sdate will start with IC date/cycle time (not
                                                #  00Hr fcst time) for BCs and count down.

        #  Test for an incorrect date from the Perl Time utility
        #
        my $tdate = substr(&EMS_time::calcDate($sdate,0),0,10);

        if ($tdate > $sdate) {
            $mesg = "Simulation Start Date ($EMSprep{RDATE}) and Perl - A Match Not Made in EMS HQ!\n\n".
                    "The Perl time module, ,is returning an invalid date/time. This problem usually ".
                    "occurs when the initialization date of your simulation is more than 50 years older ".
                    "than the current system date.  To fix the problem you can either temporarily modify ".
                    "the Perl library or reset your system clock but I can't allow you to dig ".
                    "a deeper hole until you remedy this situation.";
            &EMS_love::died(1,$mesg); return ();
        }


        #  Check whether the requested start date is more than 23 hours ahead of the current system UTC
        #  date, in which case the user likely flubbed the --date request.
        #
        my $fdate = substr(&EMS_time::calcDate($yyyymmddxx,24*3600),0,10);
        if ($sdate > $fdate) {

            #  Format the output
            #
            my $scycl = $EMSprep{RCYCLE};
            $scycl =~ s/CYCLE/00/g;
            $sdate =~ s/23$/$scycl/g;
            $sdate = &EMS_time::formatDate($sdate);

            &EMS_style::emsprint(6,4,96,1,1,"Getting ahead of yourself are you?");
            $mesg = "The requested simulation start date, $sdate,\n".
                    "is too far in the future for me to take you seriously.\n\nTry me again, this time with some passion!";
            &EMS_love::died(1,$mesg); return ();
        }


        #  Note that we also take into account the DELAY setting from the gribinfo file for
        #  a data set here.
        #
        while (scalar @pdates < 24) { # We only want a 24-hour window of times
            $shr--; #  Count down hours
            my $pdate = substr(&EMS_time::calcDate($sdate,$shr*3600),0,10);
            next if $pdate > $yyyymmddxx; #  Data set is not available yet (00Hr after current date/time)
            next if $pdate > $yyyymmddhh; #  Data set 00Hr is after simulation 00Hr (BCs)
            my $adate = substr(&EMS_time::calcDate($pdate,$data_info->delay*3600),0,10);
            next if $adate > $yyyymmddxx; #  Data set is not available yet (Delay included)
            push @pdates => $pdate;       #  Add it to the list
        }

        #  The available cycle times for a data set is defined by the CYCLES parameter
        #  in the gribinfo.conf file. Here the list of 24 times will be paired down
        #  to just those matching those cycle times.
        #
        @{$data_info->cycles} = sort @{$data_info->cycles};


        #  The @cyls array is a list of all available cycle times according to the gribinfo
        #  file for a data set.  The actual cycle time must by pruned from the string
        #  that contains other information so that it may be used later.
        #
        my $n=0;
        my @cyls=(); # contains a list of all available cycle times for a data set
        my @cdates=();
        foreach my $str ( @{$data_info->cycles} ) {
            my @list = split /:/ => $str; #  Split the info and get the actual cycle hour
            my $cycle = sprintf("%02d", $list[0]);
            push @cyls => $cycle;
            # Extract those dates/time that coincide with a cycle time in the list
            #
            my @matches = grep /$cycle$/ => @pdates;
            @cdates = (@cdates, @matches);
        }
        @cdates = &EMS_utils::rmdups(@cdates);
        @cdates = sort {$b <=> $a} @cdates; my @acdates = @cdates;
        @cyls   = sort {$b <=> $a} @cyls;


        #  For debugging purposes
        #
        if ($EMSprep{DEBUG}) {&EMS_style::emsprint(4,13,96,1,2,"Most Current Date - $acdates[0]");}

        if ($EMSprep{DEBUG}) {&EMS_style::emsprint(4,13,96,0,1,"Available Dates   - $_") foreach @acdates;}


        #  If the --date flag was passed, eliminate those date/times not matching the request.
        #
        if ($EMSprep{RDATE}) {
            my @matches = grep /^$EMSprep{RDATE}/ => @cdates; @cdates = sort {$b <=> $a} @matches;
            if ($EMSprep{DEBUG}) {&EMS_style::emsprint(4,13,96,0,1,"Matching $EMSprep{RDATE} Date  - $_") foreach @cdates;}
        }


        #  By now we should have a list of all dates and cycle times going make 24 hours
        #

        #  The default behavior is to use the most recent data set in the cdates list unless the
        #  the user has passed the --cycle or --previous fleg.
        #
        #  Passing the previous flag states that the user does not want the most current data set
        #  available, but rather, the first data set available before the current one. The
        #  00hr of the forecast will remain the same as that without passing the --previous
        #  flag but the file date/times used will be adjusted accordingly.
        #

        #  Note that if the user overrides the BCFREQ option (BC frequency) from the command
        #  line using the --cycle flag then this value will be applied to whatever BC data
        #  set is being used for BC data.
        #
        if ($data_info->useid != 3) { # This is not a BC data set

            #  Extract the cycle time of the most current date in list.  This is in the
            #  event that the user has passed the --cycle flag with the "CYCLE" argument.
            #
            my $cc = &EMS_time::dateStrings($cdates[0], 'cc');
            $EMSprep{RCYCLE} =~ s/CYCLE/$cc/g; # replaces "CYCLE" with most current cycle


            #  Split the argument to --cycle and check if the user is overriding
            #  the default values from the gribinfo file.
            #
            my ($urc, $uri, $urf, $urq) = split /:/ => $EMSprep{RCYCLE};
            $urq = 3 if $urq and $urq <= 0;


            #  If the user requested the BC freq we need to keep this information
            #
            $rbcfreq = $urq ? $urq : 0;


            #  Extract the default cycle information for the requested cycle
            #

            #  Start with the basics from the gribinfo file
            #
            $iinitfh = $data_info->initfh;
            $ifinlfh = $data_info->finlfh;
            $ifreqfh = $data_info->freqfh;


            #  Override with CYCLE parameter from gribinfo file. The CYCLE
            #  parameter values override INITFH, FINLFH, and FREQFH
            #
            if (grep (/^$urc/ => @{$data_info->cycles})) {
                my @str = grep (/^$urc/ => @{$data_info->cycles});
                my ($drc, $dri, $drf, $drq) = split /:/, $str[0];

                $iinitfh = $dri if $dri;
                $ifinlfh = $drf if $drf;
                $ifreqfh = $drq if $drq;
            } else {
                if ($abcfreq) {
                    $mesg = "The $abcfreq hour forecast frequency of the $rdsets[1] boundary condition data set has reduced ".
                            "the number of $rdsets[0] cycle times available for initialization.\n\nAnd Mr. $urc UTC cycle time, ".
                            "you're not on the list!";

                } else {
                    $mesg = sprintf ("According to the %s\_gribinfo.conf file, there is no such thing as ".
                                     "a $urc UTC cycle time for the %s data set.",$data_info->dset,$data_info->dset);
                }

                $mesg = "Hey, That\'s Not a Cycle Time!\n\n$mesg";
                &EMS_love::died(1,$mesg); return ();
            }


            #  Override those with user command-line values if necessary
            #
            $iinitfh = $uri if $uri;  $iinitfh = 0 unless $iinitfh;
            $ifinlfh = $urf if $urf;
            $ifreqfh = $urq if $urq;

            #  Test for NAM 218 grid
            #
            #  Hourly files are only available through 36 hours so if the final
            #  forecast hour is greater than 36 use 3-hourly files.
            #
            #  Lots of "if"s here
            #
            $ifreqfh = 3 if $Info{bds} and $Info{bds} =~ /nam/i and $ifinlfh > 36 and $ifreqfh < 3;


            #  Make sure the user has requested a valid cycle time
            #
            unless (grep /$urc$/ => @cyls) {
                $mesg = sprintf ("According to the %s\_gribinfo.conf file, there is no $urc UTC cycle time ".
                                 "for the %s data set.",$data_info->dset,$data_info->dset);
                $mesg = "Hey, That\'s Not a Cycle Time!\n\n$mesg";
                &EMS_love::died(1,$mesg); return ();
            }


            #  Extract the date/cycle that matched the requested cycle. there should be only 1.
            #
            my @matches = grep /$urc$/ => @cdates;


            #  Make sure there are dates available. If @matches is empty then nothing matched.
            #
            unless (@matches) {

                &EMS_style::emsprint(6,6,96,0,1,"You have requested an initialization data set that is not yet available.");

                $urc = ($EMSprep{RCYCLE} and $urc) ? "- $urc UTC" : " ";

                if ($EMSprep{RCYCLE} and $EMSprep{RCYCLE} and $urc) {
                    $mesg = "Your Requested Date : $EMSprep{RDATE} $urc";
                } elsif ($EMSprep{RCYCLE} and $urc) {
                    $mesg = "The Requested Cycle Time : $urc";
                } elsif ($abcfreq) {
                    $mesg = "Incompatible initialization time with boundary condition update frequency";
                } else {
                    $mesg = "Something is wrong with initialization date/time";
                }
                &EMS_style::emsprint(0,19,96,1,2,$mesg);

                if (@acdates) {
                    &EMS_style::emsprint(0,19,96,0,2,"A List of Possible Initialization Date & Times:");
                    foreach (@acdates) {
                        my $d = substr $_,0,8;
                        my $c = substr $_,8,2;
                        &EMS_style::emsprint(0,41,96,0,1,"$d - $c UTC");
                    }
                }
                my $dset  = $data_info->dset;
                my $delay = $data_info->delay;
                   $delay = $delay > 1 ? "$delay hours" : "$delay hour";
                $mesg = "Note that the $dset data set is typically available $delay after the cycle time.";
                &EMS_love::died(1,$mesg); return ();
            }


            # define the date/cycle of the initialization data set - for now
            #
            $yyyymmddcc = $matches[0];


            #  Define the 00 hour of the simulation. This is important to take into account
            #  the requested initial forecast hour to use.
            #
            $EMSprep{RUN00H} = substr(&EMS_time::calcDate($yyyymmddcc,$iinitfh*3600),0,10);


            #  $yyyymmddhh defines the date/time of the first data set file to download.
            #  This is not necessarily the date/cycle time of the data set or the 00 hour
            #  of the simulation; however, it may be the same as the 00Hr simulation time.
            #  For this purpose it is the same as the simulation 00Hr.
            #
            $yyyymmddhh     = $EMSprep{RUN00H};

            if ($EMSprep{PREVIOUS}) {

                #  If the user passed the --previous flag then:
                #
                #  1. We want the 00 hour of the simulation defined by the information
                #     provided by the user either by default or otherwise.
                #
                #  2. We need to account for the delta between the 00 hour of the simulation
                #     and the 00 hour of the requested data set.
                #

                #  Go through the list of cdates and when the date matching $yyyymmddcc is
                #  encountered grab the previous one.
                #
                my $prev;
                for my $i (1 .. $#cdates) {$prev = $cdates[$i] if $cdates[$i-1] == $yyyymmddcc;}

                unless ($prev) {
                    $mesg = "Sorry but there were no previous cycle defined prior to $yyyymmddcc. ".
                            "this may be because you passed the --date flag, which you should not ".
                            "do if this is a real-time run and the --previous flag is only for ".
                            "real-time forecasting.";
                    &EMS_love::died(1,$mesg); return ();
                }

                #  Get the delta in hours
                #
                my $delta = int ((&EMS_time::epocSecs($yyyymmddcc)-&EMS_time::epocSecs($prev))/3600);

                $iinitfh = $iinitfh + $delta;
                $ifinlfh = $ifinlfh + $delta;

                $matches[0] = $prev;
            }


            #  Define the date/cycle of the data set
            #
            @cdates = @matches;
            $EMSprep{YYYYMMDDCC} = $cdates[0];


            #  Define the period for the data set, which depends on whether this data set
            #  will only be used for ICs or for the full run.
            #
            if (scalar(@{$EMSprep{DSTRUCTS}}) == 1) {  # full run

                $EMSprep{FLENGTH} = $ifinlfh - $iinitfh unless $EMSprep{FLENGTH};

                #  If this is a global run then only the IC file is needed regardless
                #  of the simulation length UNLESS nudging is turned ON, then we need 
                #  them all.
                #
                $ifinlfh = ($EMSprep{GLOBAL} and !$EMSprep{NUDGING}) ? $iinitfh : $iinitfh + $EMSprep{FLENGTH};

            } else { # This is just the IC data set

                $ifinlfh = $iinitfh;

            }


            #  If the user requested that the run be initialized from a series of analyses
            #
            if (defined $EMSprep{ANAL}) {
                my $afreq = scalar @cyls > 1 ? $cyls[0]-$cyls[1] : 24;
                my $freq = $data_info->freqfh;
                $freq ? $data_info->freqfh($freq) : $data_info->freqfh($afreq);

                $EMSprep{ANAL} =  sprintf("%02d", $EMSprep{ANAL});
            }


            #  Need to populate the start times for the various WPS namelist parameters
            #
            #  Start with the parent domain
            #
            @{$EMSprep{MASTERNL}{SHARE}{start_date}} = ();
            @{$EMSprep{MASTERNL}{SHARE}{end_date}}   = ();

            my $sdate = &EMS_time::date2wrfstr(&EMS_time::calcDate($yyyymmddhh, 0));
            my $edate = &EMS_time::date2wrfstr(&EMS_time::calcDate($yyyymmddhh, $EMSprep{FLENGTH}*3600));

            #  Define the end date of domain 1 simulation data set for debugging and other purposes
            #
            $EMSprep{REDATE} = &EMS_time::wrfStr2Date($edate);


            $data_info->rsdate($EMSprep{RUN00H});
            $data_info->redate($EMSprep{REDATE});

            $Info{sdate} = &EMS_time::formatDate($sdate);
            $Info{edate} = &EMS_time::formatDate($edate);

            $EMSprep{MASTERNL}{SHARE}{start_date}[0] = "\'$sdate\'";
            $EMSprep{MASTERNL}{SHARE}{end_date}[0]   = "\'$edate\'";


            #  Now do the child domains
            #
            #  Fill in the requested start and stop times for the requested nested domains.
            #
            for my $dom (sort {$a <=> $b} keys %{$EMSprep{DOMAINS}}) {
                next unless $dom > 1;

                #  In the event of a global simulation the nested simulation must have
                #  the same start time as the parent.
                #
                if ($EMSprep{DOMAINS}{$dom} and $EMSprep{GLOBAL}) {
                    $mesg = "Start Time Problem for Nested Domain:\n\n".
                            "The start time for any domain nested within a global simulation must be the ".
                            "the same\nas the primary (global) domain.Change the \"${dom}:$EMSprep{DOMAINS}{$dom}\" ".
                            "to \"${dom}::\" and try again.";
                    &EMS_love::died(1,$mesg); return ();
                }
                my $sdate = &EMS_time::date2wrfstr(&EMS_time::calcDate($yyyymmddhh, $EMSprep{DOMAINS}{$dom}*3600));
                if ($EMSprep{DOMAINS}{$dom} >= $EMSprep{FLENGTH}) {
                    $mesg = "Start Time Problem for Nested Domain $dom:\n\n".
                            "The start time for domain $dom ($sdate) is after the simulation, has ended ($edate), ".
                            "which is not good\nunless you are trying to start a hullabaloo or something.";
                    &EMS_love::died(1,$mesg); return ();
                }
                $EMSprep{MASTERNL}{SHARE}{start_date}[$dom-1] = "\'$sdate\'";
                $EMSprep{MASTERNL}{SHARE}{end_date}[$dom-1]   = $EMSprep{NUDGING} ? "\'$edate\'" : "\'$sdate\'";
                $Info{domains}{$dom}{sdate} = &EMS_time::formatDate($sdate);
            }

            #  Assign the name of the METGRID.TBL file to be used.
            #
            ($EMSprep{METTBL} = $data_info->mtable) =~ s/CORE/$EMSprep{CORE}/g;


        } else { #  This is a BC data set

            #  Set the BC frequency of the data set
            #
            $ifreqfh = $data_info->freqfh;


            #  Reassign the BC freq if requested to do so
            #
            $ifreqfh = $rbcfreq if $rbcfreq;


            #  Need to figure out what forecast time to start with, which hopefully will be
            #  determined from $EMSprep{RUN00H} + $ifreqfh
            #
            $yyyymmddhh = substr(&EMS_time::calcDate($EMSprep{RUN00H},$ifreqfh*3600),0,10);


            #  $cdates[0] should contain the date/cycle time of the data set to use for BCs.
            #  Now figure out the forecast.
            #
            $iinitfh = int ((&EMS_time::epocSecs($yyyymmddhh)-&EMS_time::epocSecs($cdates[0]))/3600);

            #  Define the time period
            #
            $ifinlfh = $iinitfh + $EMSprep{FLENGTH} - $ifreqfh;

            #  Test for NAM 218 grid
            #
            #  Hourly files are only available through 36 hours so if the final
            #  forecast hour is greater than 36 use 3-hourly files.
            #
            if ($Info{bds} =~ /nam/i and $ifreqfh < 3 and $ifinlfh > 36) {
                $ifreqfh = 3; # set to 3 hourly
                $yyyymmddhh = substr(&EMS_time::calcDate($EMSprep{RUN00H},$ifreqfh*3600),0,10);
                $iinitfh = int ((&EMS_time::epocSecs($yyyymmddhh)-&EMS_time::epocSecs($cdates[0]))/3600);
                $ifinlfh = $iinitfh + $EMSprep{FLENGTH} - $ifreqfh;
            }

            $data_info->rsdate($EMSprep{RUN00H});
            $data_info->redate($EMSprep{REDATE});

        }


        #  So as not to become confused:
        #
        #  $yyyymmddcc - $yyyymmddcc represents the date & cycle time
        #                of the data set to be used for IC or BCs
        #
        #                Carried in $EMSprep{YYYYMMDDCC} for IC data set. This
        #                is used later in the code.
        #
        #                Carried in $data_info->yyyymmdd and $data_info->acycle
        #                for each data set.
        #
        #  $yyyymmddhh - The $yyyymmddhh represents the date & hour of
        #                first period to be used from the data set
        #                identified by $yyyymmddcc.  Note that
        #                $yyyymmddhh >= $yyyymmddcc.
        #
        #                Carried in $data_info->zerohr for each data set
        #
        #  $EMSprep{RUN00H} - The 00Hr Date & Time of the simulation
        #
        #                Carried in $data_info->rzerohr for each data set
        #
        $yyyymmddcc = $cdates[0];
        $yyyymmdd   = &EMS_time::dateStrings($yyyymmddcc, 'yyyymmdd');
        $acycle     = &EMS_time::dateStrings($yyyymmddcc, 'cc');

        for ($iinitfh, $ifinlfh, $ifreqfh) {$_ = sprintf("%02d", $_);}

        #  Define some of the fields in the data type structure
        #
        $data_info->mtable($EMSprep{METTBL});
        $data_info->initfh($iinitfh);
        $data_info->finlfh($ifinlfh);
        $data_info->freqfh($ifreqfh);
        $data_info->yyyymmdd($yyyymmdd);
        $data_info->acycle($acycle);
        $data_info->zerohr($yyyymmddhh);
        $data_info->rzerohr($EMSprep{RUN00H});
        $data_info->length($EMSprep{FLENGTH});

        $Info{bcfreq} = int ($data_info->freqfh * 60 + 0.49) unless $data_info->useid == 2;


        unless ($data_info->useid == 2) {
            my $bcf = $data_info->freqfh; $bcf+=0;
            #  Make sure that the forecast update frequency divides evenly into the length
            #  of the forecast
            if ($EMSprep{FLENGTH} % $bcf) {
                $mesg = "Forecast Length Problem:\n\n".
                        "The specified BC update frequency ($bcf hours) does not divide evenly into the\n".
                        "requested length of the forecast ($EMSprep{FLENGTH} hours), which is not good unless you\n".
                        "are trying to start a hullabaloo or something.";
                &EMS_love::died(1,$mesg); return ();
            }
        }

        #  Make sure nothing stupid was done like setting freqfh to 0.
        #
        $data_info->freqfh(3) if $data_info->freqfh < 0;

        while ( my ($key, $val) = each(%{$EMSprep{DOMAINS}}) ) {
            $EMSprep{HIRESBC} = 1 if $val and $val % $data_info->freqfh;
        }

        &Putils::printDataSet($data_info) if $EMSprep{DEBUG};
    }


    #  Populate the structure for the surface data sets such as sst and find
    #  an appropriate date/time to use.
    #
    foreach my $data_info (@sstructs) {

        my $acycle;
        my $yyyymmddhh = $yyyymmddxx; # Set to current date/time just to start
        my $ds         = $data_info->dset;

        push @{$Info{sfc}} => $ds;

        &EMS_style::emsprint(1,6,96,0,2,"Static Surface Data Sets") if $EMSprep{DEBUG};

        @{$data_info->cycles} = sort @{$data_info->cycles};

        #  Handle the request for the "best hour" data set
        #
        my @besthr = ();
        @besthr    = split /,/ => $EMSprep{BESTHR} if $EMSprep{BESTHR};
        $data_info->besthr(1) if grep (/^$ds$/i, @besthr);

        if ($data_info->besthr) {
            #  Determine the best cycle hour to use
            #
            my $zh = substr ($EMSprep{RUN00H},8,2);
            my $dc = 25; # 25 hours > 1 day
            my @bcs=();
            foreach my $str (@{$data_info->cycles}) {
                my @list = split(/:/,$str); my $cycle = $list[0];
                my $diff = abs ($cycle - $zh);
                if (abs ($cycle - $zh) < $dc) {
                    $dc = abs ($cycle - $zh);
                    @bcs = ();
                    push @bcs => $str;
                } elsif (abs ($cycle - $zh) == $dc) {
                    push @bcs => $str;
                }
           }
           @{$data_info->cycles} = @bcs;

           my $bhs = scalar @bcs > 1 ? join " or " => @{$data_info->cycles} : shift @bcs; $bhs = uc $bhs;
           $bhi = sprintf("Using $ds data from $bhs UTC cycle%s as closest time match for $zh UTC simulation start",scalar @bcs > 1 ? "s" : "");
        }


        #  The requirement for the date/time used for static surface fields, such as SST, and
        #  not as strict as those for the other data types.
        #
        #  We have the date/time of the 00 hour forecast.  Make a list of all hours from
        #  simulation 00Hr back to simulation 00Hr-24Hrs (24 hours total) that will
        #  be used to match to a surface data set.
        #
        #  If the "best hour" option is requested then make a list of from simulation
        #  00Hr+6Hrs back to simulation 00Hr-18Hrs (24 hours total).
        #
        my @pdates=();

        my $shr = $data_info->besthr ? 7 : 1;

        while (scalar @pdates < 25) {
            $shr--; #  Count down hours
            my $pdate = substr(&EMS_time::calcDate($EMSprep{RUN00H},$shr*3600),0,10);
            next if $pdate > $yyyymmddxx; #  Data set is not available yet (00Hr after current date/time)
            my $adate = substr(&EMS_time::calcDate($pdate,$data_info->delay*3600),0,10);
            next if $adate > $yyyymmddxx; #  Data set is not available yet (Delay included)
            push @pdates => $pdate;       #  Add it to the list
        }

        #  Now attempt to match cycle times to list of available date/times
        #
        my @sdates=();
        foreach my $str (sort @{$data_info->cycles} ) {
            my @list = split(/:/,$str); my $cycle = $list[0];
            my @matches = grep /$cycle$/ => @pdates;
            @sdates = (@sdates, @matches);
        }
        @sdates = &EMS_utils::rmdups(@sdates);
        @sdates = sort {$b <=> $a} @sdates;

        if ($EMSprep{DEBUG}) {&EMS_style::emsprint(4,13,96,0,1,"Available date - $_") foreach @sdates;}

        #  Needed below
        #
        $yyyymmddcc = $sdates[0];
        $yyyymmdd   = &EMS_time::dateStrings($yyyymmddcc, 'yyyymmdd');
        $acycle     = &EMS_time::dateStrings($yyyymmddcc, 'cc');

        $data_info->acycle($acycle);
        $data_info->yyyymmdd($yyyymmdd);


        $data_info->initfh("00");
        $data_info->finlfh("00");
        $data_info->freqfh("01"); #  Needs to be > 0
        $data_info->length("00");

        $data_info->rzerohr($EMSprep{RUN00H});
        $data_info->zerohr($yyyymmddcc);  #  Date & time of data set

        $data_info->rsdate($EMSprep{RUN00H});
        $data_info->redate($EMSprep{REDATE});

        push @{$EMSprep{DSTRUCTS}} => $data_info;

        &Putils::printDataSet($data_info) if $EMSprep{DEBUG};
    }


    foreach my $struct (@lstructs) {

        my $data_info = $struct;

        #  Traverse the linked list of primary LSM data sets and back ups
        #
        while (defined $data_info) {

            my $acycle;
            my $ds = $data_info->dset;
            push @{$Info{lsm}} => $ds;

            my $yyyymmddhh = $yyyymmddxx; # Set to current date/time just to start

            &EMS_style::emsprint(1,6,96,0,2,"Land Surface Data Sets") if $EMSprep{DEBUG};

            #  The handling of the time-dependent data sets, such as LSM, is different from
            #  that of the static data sets. Besides the need for data that covers the entire
            #  period of the simulation, there must be a date/time that coincides with the
            #  00hr of the simulation.  Also, for consistency, the date/time of the data set
            #  must be near the date/time of the initialization data set, which is not
            #  necessarily the same date/time as the 00Hr of the simulation.
            #
            my @pdates=();
            my $shr   =1;

            #  Use $EMSprep{RUN00H} as the reference date/time because that is the date/time
            #  of the model initialization. - Thanks to Jon Case (ENSCO) for the fix
            #
            while (scalar @pdates < 25) {
                $shr--; #  Count down hours
                my $pdate = substr(&EMS_time::calcDate($EMSprep{RUN00H},$shr*3600),0,10);
                next if $pdate > $yyyymmddxx; #  Date is in the future
                my $adate = substr(&EMS_time::calcDate($pdate,$data_info->delay*3600),0,10);
                next if $adate > $yyyymmddxx; #  Data are not available yet
                push @pdates => $pdate;       #  Add it to the list
            }


            #  Now attempt to match cycle times to list of available date/times
            #
            my @ldates=();
            foreach my $str (sort @{$data_info->cycles} ) {
                my @list = split(/:/,$str); my $cycle = $list[0];
                my @matches = grep /$cycle$/ => @pdates;
                @ldates = (@ldates, @matches);
            }
            @ldates = &EMS_utils::rmdups(@ldates);
            @ldates = sort {$b <=> $a} @ldates;

            if ($EMSprep{DEBUG}) {&EMS_style::emsprint(4,13,96,0,1,"Available date - $_") foreach @ldates;}

            unless (@ldates) {
                $mesg = "Problem with LSM Initialization:\n\n".
                        "No $ds LSM data files could be found that correspond to the initialization ".
                        "time of the simulation ($EMSprep{RUN00H}). Are the cycle times or the ".
                        "delay setting in the $ds\_gribinfo.conf correct?";
                &EMS_love::died(1,$mesg); return ();
            }

            #  Needed below
            #
            $yyyymmddcc = $ldates[0];
            $yyyymmdd   = &EMS_time::dateStrings($yyyymmddcc, 'yyyymmdd');
            $acycle     = &EMS_time::dateStrings($yyyymmddcc, 'cc');

            $data_info->acycle($acycle);
            $data_info->yyyymmdd($yyyymmdd);

            #  Calculate the difference in hours between the available initial condition and
            #  LSM data sets.
            #
            my $lcyr = substr ($data_info->yyyymmdd,0,4);
            my $lcmo = substr ($data_info->yyyymmdd,4,2);
            my $lcdy = substr ($data_info->yyyymmdd,6,2);
            my $lccc = $acycle;

            my $icyr = substr ($EMSprep{RUN00H},0,4);
            my $icmo = substr ($EMSprep{RUN00H},4,2);
            my $icdy = substr ($EMSprep{RUN00H},6,2);
            my $iccc = substr ($EMSprep{RUN00H},8,2);

            my $bcsecs = timegm( 0, 0, $lccc, $lcdy, $lcmo-1, $lcyr);
            my $icsecs = timegm( 0, 0, $iccc, $icdy, $icmo-1, $icyr);

            my $dth = ($icsecs - $bcsecs) / 3600;


            if ($dth < 0) {
                $mesg = "Initialization Problems:\n\n".
                        "LSM data set is more recent than initial conditions ($EMSprep{RUN00H} < $yyyymmddcc)";
                &EMS_love::died(1,$mesg); return ();
            }
            $dth = int $dth;

            #  Handle whether the LSM data are time dependent, meaning that we will need file for each
            #  BC time through the length of the forecast.
            #
            $data_info->initfh($dth);
            if ($data_info->timed) {
                #  correction for NAM hourly data with fcst greater than 36 hours
                #
                $data_info->finlfh($data_info->initfh + $EMSprep{FLENGTH});
                $data_info->length($EMSprep{FLENGTH});
            } else {
                #$dth = 3 if ($Info{bds} =~ /nam/i) and ($dth < 3) and (($dth + $EMSprep{FLENGTH}) > 36);
                $data_info->finlfh($data_info->initfh);
                $data_info->length($data_info->initfh - $dth);
            }
            $data_info->rzerohr($EMSprep{RUN00H});
            $data_info->zerohr($yyyymmddcc);
            $data_info->rsdate($EMSprep{RUN00H});
            $data_info->redate($EMSprep{REDATE});

            &Putils::printDataSet($data_info) if $EMSprep{DEBUG};

            #  Move along to next link in the list
            #
            $data_info = $data_info->nlink;

        }
        push @{$EMSprep{DSTRUCTS}} => $struct;
    }

    #  Set the current date on the machine for error checking in Pacquire.pm
    #
    $EMSprep{CDATTIM} = $yyyymmddxx;


    #  Determine whether the user wants to use the alternate method of SST initialization inwhich the 
    #  mean surface temperatures for a 24 hour period are calculated and use for SST values should
    #  no other data source be available.  THis is indicated by the value of the ISLAKE variable in
    #  domain 1 geo_ data set.
    #
    unless ($EMSprep{NOALTSST}) {
        opendir DIR => $EMSprep{STATIC};
        foreach (sort grep /\.d01\.nc$/ => readdir DIR) {$EMSprep{NOALTSST} = (&EMS_files::readVarCDF("$EMSprep{STATIC}/$_",'ISLAKE') == -1) ? 1 : 0;} 
        close DIR;
    }


    #  Provide some general information about the Initialization
    #
    $mesg = sprintf("%5s  STRC EMS ems_prep Simulation Initialization Summary",shift @{$EMSprep{RN}});
    &EMS_style::emsprint(0,2,96,0,2,$mesg);

    my $sfc = defined $Info{sfc} ? join ", " => @{$Info{sfc}} : 'None';
    my $lsm = defined $Info{lsm} ? join ", " => @{$Info{lsm}} : 'None';

    if ($EMSprep{GLOBAL}) {
        $mesg = "Initialization Start Time    : $Info{sdate}\n".
                "Initialization End   Time    : $Info{edate}\n".
                "Initialization Data Set      : $Info{ids}\n".
                "Static Surface Data Sets     : $sfc\n".
                "Land Surface Data Sets       : $lsm";
    } else {
        my $bcf = sprintf("$Info{bcfreq} Minute%s",$Info{bcfreq} == 1 ? "" : "s");
        $mesg = "Initialization Start Time    : $Info{sdate}\n".
                "Initialization End   Time    : $Info{edate}\n".
                "Boundary Condition Frequency : $bcf\n".
                "Initialization Data Set      : $Info{ids}\n".
                "Boundary Condition Data Set  : $Info{bds}\n".
                "Static Surface Data Sets     : $sfc\n".
                "Land Surface Data Sets       : $lsm";
    }

    &EMS_style::emsprint(0,11,96,0,1,$mesg);
    &EMS_style::emsprint(1,11,88,1,2,$bhi) if $bhi;
    &EMS_style::emsprint(0,9,88,1,2,"This is a GLOBAL simulation - Going global!") if $EMSprep{GLOBAL};

    $mesg = "Included Sub-Domains:\n\n".
            "    Domain    Parent    Start Date\n";
    &EMS_style::emsprint(0,11,96,1,1,$mesg) if @rdoms;
    foreach my $dom (@rdoms) {
        &EMS_style::emsprint(0,18,96,0,1,"$dom         $Info{domains}{$dom}{parent}      $Info{domains}{$dom}{sdate}");
    }

    &EMS_style::emsprint(0,11,96,0,1,"\n") if @rdoms;

return %EMSprep;

} # End of configure



sub gribinfo {
#----------------------------------------------------------------------------------
#  This routine takes input from the --dsets, --lsm and --sfc options, parses out
#  the data set to be used , opens and reads the appropriate _gribinfo.conf file
#  and then opulates a hash with all the default information.
#----------------------------------------------------------------------------------
#
use Class::Struct;
use Pstruct;

    my ($fstruct,$cstruct);

    my ($tds, $tid) = @_;


    #  Split the list at each pipe "|". This is currently done to handle the
    #  LSM fail-over options but may be used other places in the future.
    #
    foreach (split /\|/ => $tds) {

        #  Initialize the values used in the data structure
        #
        my %sources=();
        my (@flist,@gribs,@cycles,@tiles); @flist = @gribs = @tiles = @cycles = ();

        my ($delay,$initfh,$finlfh,$aged,$timed,$besthr); $delay = $initfh = $finlfh = $aged = $timed = $besthr = 0;
        my ($info,$model,$loclfil,$archdir,$vtable,$ltable);

        my $mtable = "METGRID.TBL.CORE";
        my $vcoord  = 'unknown';
        my ($freqfh, $maxfreq); $freqfh = $maxfreq = 1;

        #  Split the individual data sets
        #
        my ($dset,$method,$host,$loc) = split /:|;|,/,$_,4;


        #  Handle some special conditions related to users not specifying a
        #  host for the NFS method.
        #
        if ($host and $host =~ /\//) {$loc = $host; $host = 'LOCAL';}
        $host = 'LOCAL' if $host and $host eq 'local';
        unless ($host) {$host = 'LOCAL' if $method and lc $method eq 'nfs' and $loc;}

        my $nfs  = ($method and (grep /^$method$/i, qw(nonfs  ftp http))) ? 0 : 1;
        my $ftp  = ($method and (grep /^$method$/i, qw(noftp  nfs http))) ? 0 : 1;
        my $http = ($method and (grep /^$method$/i, qw(nohttp nfs ftp)))  ? 0 : 1;

        #  Resolve the hostname if included
        #
        $host = &hkey_resolv($host,%{$EMSprep{HKEYS}}) if $host;

        if ($method and $host and $loc) {
            #  Special case when user specifies method, host and location.
            #  Turn off all methods but befine source here.
            #
            $sources{FTP}{$host}  = $loc if $ftp;
            $sources{HTTP}{$host} = $loc if $http;
            $sources{NFS}{$host}  = $loc if $nfs; 

            $nfs = $ftp = $http = 0;
        }


        #  Use the user requested data set to determine which grib
        #  information file to open.
        #
        my $file  = "$EMSprep{GRIBCONF}/${dset}_gribinfo.conf";
        unless (-s $file) {&EMS_love::died(1,"A message from your personal EMS:","Global configuration ($file) - $!"); return ();}


        #  Read the grib information file and populate the data structure. Some fields
        #  are defined with temporary values until appropriate ones are calculated.
        #
        open INFILE => $file;
        while (<INFILE>) {

            chomp;
            
            s/^ +//g;s/\t|\n//g;
            next if /^#|^$|^\s+/;
            next unless /\w/;
            next unless /./;

            s/ //g unless /INFO|MODEL/i;

            #  split the line at the "="
            #
            my ($var, $value) = split(/\s*=\s*/, $_, 2);
            for ($var) {

                if (/INFO/i)   {s/^\s*//g;$info   = $value; next;}
                if (/MODEL/i)  {s/^\s*//g;$model  = $value; next;}
                if (/VCOORD/i) {s/^\s*//g;$vcoord = $value; next;}
                if (/LOCFIL/i) {$value =~ s/(.gz)$|(.bz2)$|(.bz)$//g; $loclfil = "$EMSprep{GRIBDIR}/$value"; next;} #  remove for compressed files
                if (/DELAY/i)  {$delay  = $value; next;}
                if (/INITFH/i) {$initfh = $value; next;}
                if (/FINLFH/i) {$finlfh = $value; next;}
                if (/FREQFH/i) {$freqfh = $value == 0 ? 01 : sprintf("%02d", $value);}
                if (/MAXUDFREQ/i) {$maxfreq = $value == 0 ? 01 : $value;}
                if (/AGED/i)   {$aged   = $value; next;}
                if (/LVTABLE/i){$ltable = $value; next;}
                if (/VTABLE/i) {$vtable = $value; next;}
                if (/METGRID/i){$mtable = $value; next;}
                if (/BESTHR/i) {$besthr = $value; next;}

                if (/TIMEDEP/i){$timed  = $value =~ /^Y/i ? 1 : 0; next;}

                if (/TILES/i) {next;} # Eliminated support for NCEP tiles


                if (/CYCLES/i){
                    for ($value) {s/ +//g; s/,+|;+/ /g;@cycles = split / /;}
                    my @clist=();
                    foreach my $str (@cycles) {
                        my @list = split(/:/,$str);
                        foreach (@list) {
                            if (/\D/) {
                                $_ = uc $_;
                                s/S//g; # eliminate trailing "S"
                                s/BCFREQ/FREQFH/g;
                                s/[CYCLE|INITFH|FINLFH|FREQFH]//g; # catch screw-ups
                            } else { #  all digits - want padded
                                $_ = sprintf("%02d", $_);
                            }
                        }
                        my $tmp = join ":", @list;
                        push @clist => $tmp;
                     }
                     @cycles = sort @clist;
                     next;
                }

                if (/SERVER-FTP/i){
                    next unless $ftp;
                    for ($value) {
                        s/,+|;+| +//g;
                        my @list = split (/:/,$_,2);
                        if ($list[0] and $list[1]) {
                            my $rhost = &hkey_resolv(uc $list[0],%{$EMSprep{HKEYS}});
                            next unless $rhost;
                            next if $host and $host ne $rhost;
                            $sources{FTP}{$rhost} = $list[1];
                        } else {
                            &EMS_style::emsprint(6,7,104,1,1,sprintf("Mis-configured SERVER-FTP entry (Line with %s)",$list[0] ? $list[0] : $list[1]));
                        }
                    }
                    next;
                }


                if (/SERVER-HTTP/i){
                    next unless $http;
                    for ($value) {
                        s/,+|;+| +//g;
                        my @list = split (/:/,$_,2);
                        if ($list[0] and $list[1]) {
                            my $rhost = &hkey_resolv(uc $list[0],%{$EMSprep{HKEYS}}); 
                            next unless $rhost;
                            next if $host and $host ne $rhost;
                            $sources{HTTP}{$rhost} = $list[1];
                        } else {
                            &EMS_style::emsprint(6,7,104,1,1,sprintf("Mis-configured SERVER-HTTP entry (Line with %s)",$list[0] ? $list[0] : $list[1]));
                        }
                    }
                    next;
                }


                if (/SERVER-NFS/i){
                    next unless $nfs;
                    for ($value) {
                        s/,+|;+| +//g;
                        my @list = split (/:/,$_,2);
                        unless ($list[0] and $list[1]) {
                            if ($list[0]) {
                                $list[1] = $list[0];
                                $list[0] = 'LOCAL';
                            } else {
                                $list[0] = 'LOCAL';
                            }
                        }
                        $sources{NFS}{$list[0]} = $list[1];
                    }
                    next;
                }
            } # for
        }

        unless (%sources) {
            $mesg = $method ? "Hmm, I was unable to match your method request to those available in ${dset}_gribinfo.conf" :
                              "Hmm, I was unable to match any acquisition method to those available in ${dset}_gribinfo.conf";

            $mesg = "$mesg\n\nMay I suggest trying the \"--dsquery\" option?";
            &EMS_love::died(0,$mesg); return ();
        }

        # if this is a land surface data set then make sure that a Vtable has been defined (LVTABLE)
        # in the gribinfo file.
        #
        if ($tid == 4) {
            unless ($ltable) {
                $mesg = "A message from your personal EMS:\n\nData set \"$dset\" can not be used for LSM fields since there is no LVTABLE defined in $file";
                &EMS_love::died(0,$mesg); return ();
            }
            $vtable = $ltable;
        }

        if ($tid == 5) {
            unless ($info =~ /sfc/i) {&EMS_love::died(1,"A message from your personal EMS:\n\nData set $dset can not be used for static surface data\n"); return ();}
        }

        $besthr = ($besthr =~ /^Y/i and $tid == 5) ? 1 : 0;


        #  The following line is intended to force the routine to do at least one loop
        #  through the requested data sets even when tiles are not being downloaded.
        #  There are easier ways of accomplishing this task but I need to move on.
        #  It also makes sure that multiple loops are not done if the TILES field
        #  is not empty in the gribinfo.conf file.
        #  Keep this line in the code for now.
        #
        @tiles = "NA" unless @tiles and ($dset =~ /tile/i or $info =~ /tile/i);

        $archdir = defined $EMSprep{ARCHDIR} ? $EMSprep{ARCHDIR} : '';

        #  Handle the situation where the BC frequency is set to 0 in which case the
        #  value must be replaced with something more appropriate such as the time 
        #  between cycles.
        $freqfh = 1 unless defined $freqfh;
        for ($freqfh) {
            $_ = 1 if /\D/;
            $_+= 0;
            $_ = 1 unless $_;
            $_ = sprintf("%02d", $_);
        }
        

        #  Create new grib information data structure and populate values
        #  with input from file
        #
        my $struc = data_struct-> new (

            #  Filled in by gribinfo file
            #
            dset       => $dset,
            info       => $info,
            model      => $model,
            vcoord     => $vcoord,
            initfh     => $initfh,
            finlfh     => $finlfh,
            freqfh     => $freqfh,
            maxfreq    => $maxfreq,
            vtable     => $vtable,
            mtable     => $mtable,
            aged       => $aged,
            loclfil    => $loclfil,
            archdir    => $archdir,
            delay      => $delay,
            timed      => $timed,
            besthr     => $besthr,


            # Lists filled in by gribinfo file
            #
            cycles     => [@cycles],
            tiles      => [@tiles],


            # Hashes filled in by gribinfo file
            #
            sources    => {%sources},


            #  Values supplied outside routine
            #
            acycle     => 9999,
            yyyymmdd   => 9999,
            zerohr     => 9999,
            rzerohr    => 9999,
            rsdate     => 9999,
            redate     => 9999,
            length     => 0,
            flist      => [@flist],
            gribs      => [@gribs],
            format     => "Undefined",
            useid      => $tid,
            fname      => $file,
            nlink      => undef);


        #  If this is the fist time through then point fstruct and cstruct to the structure
        #
        if (defined $fstruct) { # Then must not be first time through
            $cstruct->nlink($struc);
            $cstruct = $struc;
        } else {
            $fstruct = $struc;
            $cstruct = $struc;
        }
    }

return $fstruct;
}


sub hkey_resolv {
#----------------------------------------------------------------------------------
#  This routine attempts to match a host key used in the bufrinfo.conf file with
#  an assigned hostname or IP address which is defined in the bufrgruven.conf file.
#----------------------------------------------------------------------------------
#
    my ($hkey, %keys) = @_; return unless $hkey;

    #  Check for passed IP or hostname
    #
    for ($hkey) {
        if (/^local/i)                                      {return 'local';}
        if (/^([\d]+)\.([\d]+)\.([\d]+)\.([\d]+)$/)         {return $hkey;} # IP address
        if (/^([\w]|-)+\.([\w]|-)+\.([\w]|-)+\.([\w]|-)+$/) {return $hkey;} # Hostname
        if (/^([A-Z0-9])+$/)                                {return $keys{uc $hkey} if defined $keys{uc $hkey};}  # All upper get key
        if (/^([\w]|-)+$/)                                  {defined $keys{uc $hkey} ? return $keys{uc $hkey} : return lc $hkey;} # All LC - Assume short hostname
    }

    &emsprint(6,6,84,1,1,sprintf("Could not match %s to IP or hostname. Is it defined in prep_global.conf?",$hkey));

return;
}
