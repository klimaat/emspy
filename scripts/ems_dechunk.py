#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import sys
import glob
import argparse
import datetime
import logging
import tempfile
import numpy as np

from emspy.chunk import ems_run_dir
from emspy.dechunk import WRFDataset


if __name__ == "__main__":
    
    parser = argparse.ArgumentParser(
        description="Read and form time series from a series of WRF EMS runs.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter            
        )

    parser.add_argument('domain', 
        help='specify root domain')
    
    parser_location = parser.add_mutually_exclusive_group(required=True)
    
    parser_location.add_argument('-ll', dest='ll', metavar=('lat','lon'), nargs=2, 
        type=float, help='specify lat lon of desired location')

    parser_location.add_argument('-ij', dest='ij', metavar=('i', 'j'), nargs=2, 
        type=int, help='specify i and j index of desired location')

    parser.add_argument('-n', '--nest', metavar='int',  type=int, 
        help='specify nested domain; will use finest grid available if not supplied')
        
    parser.add_argument('--spinup', dest='spinup', metavar='hours', default=12,
        type=int, help='specify spin-up time in hours')

    args = parser.parse_args()    

    # Point logging to domain.log
    logging.basicConfig(filename='%s/%s.log' % (ems_run_dir(), args.domain), level=logging.INFO, 
        format='%(asctime)s - %(message)s')
    
    # Master directory
    domainDir = '%s/%s' % (ems_run_dir(), args.domain)

    # Check to see that we have a master root domain directory
    if not os.path.isdir(domainDir):
        print 'ERROR:  Make sure %s exists' % args.domain
        raise SystemExit  

    # Figure out the number of domains
    geo = glob.glob('%s/static/geo*.nc' % domainDir)
    nDomains = len(geo)

    # Determine which domain to extract
    if args.nest:
        nest = args.nest
        # Check if requested nest exists
        if nest > nDomains:
            print 'ERROR: Requested nest %d not available.' % nest
            raise SystemExit
    else:
        # Choose finest domain
        nest = nDomains
    
    # Figure out our simulation directories
    runDirs = sorted([_ for _ in glob.glob('%s_%s' % (domainDir, '[0-9]'*8)) if os.path.isdir(_)])

    # Print header
    header = True

    # Start-up 
    # Don't know name of file as yet:  will tag it later with IJ
    # Write to a temporary file in EMS_RUN, keeping all files on same filesystem
    with tempfile.NamedTemporaryFile('wb', dir=ems_run_dir(), delete=False) as ft:
    
        # Loop over all chunks
        for runDir in runDirs:
            
            print 'De-chunking', runDir
            
            # Check if it has been run
            wrfFiles = sorted(glob.glob('%s/wrfprd/wrfout_d%02d*' % (runDir, nest)))
            if not wrfFiles:
                logging.warning('Not extracting %s; no netCDF files; skipping' % runDir)
                continue
            
            # Make sure we have only one file
            if len(wrfFiles) > 1:
                print 'ERROR:  Entire chunked simulation should reside in a single file'
                raise SystemExit
            
            logging.info('Extracting from %s' % wrfFiles[0])
                
            with WRFDataset(wrfFiles[0]) as w:

                # If latitude, longitude supplied, find indices
                if args.ll:
                    ij = w.ll2ij(*args.ll)
                else:
                    ij = args.ij
                
                # Snap to latitude and longitude based on grid found
                ll = w.ij2ll(*ij)
                
                # Calculate time of valid records 
                spinupDate = w.start_date
                spinupTimedelta = datetime.timedelta(hours=args.spinup)
                startDate = spinupDate + spinupTimedelta
                
                # Variables
                names = []
                data = []
                units = []
                fmts = []
                
                # Screen temperature (2m drybulb)
                # WRF is Kelvin; convert to Celsius
                names.append( u'Drybulb Temperature' )
                data.append( np.round(w.extract('T2', i=ij[0], j=ij[1]) - 273.15, decimals=1) )
                units.append( u'C' )
                
                # Screen humidity ratio (2m)
                # WRF is kg/kg (dry air); convert to g/kg (dry air)
                names.append(u'Humidity Ratio')
                data.append( np.round(w.extract('Q2', i=ij[0], j=ij[1])*1000., decimals=2) )
                units.append(u'g/kg')
                
                # Screen relative humidity
                # WRF is fraction [0,1]; convert to percentage
                names.append(u'Relative Humidity')
                data.append(np.round(w.extract('RH02', i=ij[0], j=ij[1])*100., decimals=0) )
                units.append(u'%')
                
                # Surface pressure
                # WRF is in Pa
                names.append(u'Surface Pressure')
                data.append(np.round(w.extract('PSFC', i=ij[0], j=ij[1]), decimals=2) )
                units.append(u'Pa')
                
                # 10m winds
                # WRF is vector and aligned with grid; need to rotate 'em
                U10 = w.extract('U10', i=ij[0], j=ij[1])
                V10 = w.extract('V10', i=ij[0], j=ij[1])
                (U10, V10) = w.rotate(U10, V10, ll[0], ll[1])
                # Convert to wind speed; m/s
                names.append(u'Wind Speed')
                data.append( np.round(np.sqrt(U10**2+V10**2), decimals=1) )
                units.append(u'm/s')
                # Convert to wind direction; degrees CW from North (azimuth/compass)
                names.append(u'Wind Direction')
                data.append( np.round(np.mod(90 - np.degrees(np.arctan2(-V10,-U10)), 360), decimals=0) )
                units.append(u'deg')
                
                # Shortwave down or Global Horizontal Radiation
                # WRF is instantaneous W/m2
                # We would like W·hr/m² i.e. integrated over previous hour
                # Approximate with average value of current & previous hour
                names.append(u'Global Horizontal Radiation')
                SWDOWN = w.extract('SWDOWN', i=ij[0], j=ij[1])
                SWDOWN[1:] = (SWDOWN[1:] + SWDOWN[0:-1])/2.0
                data.append(np.round(SWDOWN, decimals=0) )
                units.append(u'Wh/m2')
                
                # Precipitation is total accumulated since *start of sim*
                # Need hourly mm so need to subtract previous from current
                TACC_PRECIP = w.extract('TACC_PRECIP', i=ij[0], j=ij[1])
                TACC_PRECIP[1:] = TACC_PRECIP[1:] - TACC_PRECIP[0:-1]
                names.append(u'Precipitation')
                data.append(np.round(TACC_PRECIP, 3))
                units.append(u'mm')
                
                # Snow is as per precipitation but water equivalent
                TACC_SNOW = w.extract('TACC_SNOW', i=ij[0], j=ij[1])
                TACC_SNOW[1:] = TACC_SNOW[1:] - TACC_SNOW[0:-1]
                names.append(u'Snow')
                data.append(np.round(TACC_PRECIP, 3))
                units.append(u'mm')
                
                # Can easily add more variables at this point
                # e.g. skin temperature in K, converting to C
                #names.append(u'Surface Skin Temperature')
                #data.append(np.round(w.extract('TSK', i=ij[0], j=ij[1])-273.15, decimals=1))
                #units.append(u'C')
                
                # Print a header... just once
                if header:
                    
                    # Form fileName
                    fileName = '%s/%s_i%02d_j%02d.csv' % (ems_run_dir(), args.domain, ij[0], ij[1])

                    # Latitude, Longitude, Elevation
                    XLAT = w.extract('XLAT', i=ij[0], j=ij[1], t=0)
                    XLON = w.extract('XLONG', i=ij[0], j=ij[1], t=0)
                    HGT = w.extract('HGT', i=ij[0], j=ij[1], t=0)
                    
                    # Write out some information about the location
                    ft.write(('# %s %.4f degN %.4f degE %.1f m\n' % 
                            (args.domain, XLAT, XLON, HGT)
                            ).encode('utf8')
                        )
            
                    # The variables
                    names = ['Year','Month','Day','Hour'] + names
                    ft.write((','.join(names)+'\n').encode('utf8'))

                    # The units
                    units = ['yyyy','mm','dd','hh'] + units
                    ft.write((','.join(units)+'\n').encode('utf8'))
                    
                    header = False
                
                # Loop carefully over all times
                for i, t in enumerate(w.times):
                    
                    # Ignore everything in the spinup period
                    if t <= startDate:
                        continue
                        
                    # Dial time back a smidge so that we can put hours [1,24]
                    t -= datetime.timedelta(seconds=1)

                    # The data
                    datarow = ['%d' % t.year, '%d' % t.month, '%d' % t.day, '%d' % (t.hour+1)] + \
                                ['%.6g' % data[_][i] for _ in range(len(data))]
                    ft.write((','.join(datarow)+'\n').encode('utf8'))
                        
                        
        # Grab temporary file name
        tmpFileName = ft.name
    
    # Move temp to perm
    os.rename(tmpFileName, fileName)
    
