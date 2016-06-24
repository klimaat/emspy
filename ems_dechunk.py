#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import glob
import argparse
import datetime
import logging
import numpy as np
from netCDF4 import Dataset


# Establish EMS_RUN
try:
    EMS_RUN = os.environ['EMS_RUN']
except KeyError:
    logging.error('EMS_RUN does not exist.  Have you installed WRF EMS?')
    raise

def center(longitude):
    """
    Ensure longitude is within -180 to +180
    """
    return ((longitude + 180.0) % 360) - 180.0


class WRFArray(np.ndarray):
    """
    Subclass numpy ndarray to include units attribute
    """

    def __new__(cls, input_array, units=None, desc=None):
        obj = np.asarray(input_array).view(cls)
        return obj

    def __init__(self, input_array, units=None, desc=None):
        self.units = units
        self.desc = desc


class WRFDataset(object):

    """
    Class for conversion of geographical latitude and longitude values to
    the cartesian x, y on a Lambert Conformal projection.
    Adapted from Fortran subroutine llij_lc in read_wrf_nc.f
    http://www2.mmm.ucar.edu/wrf/src/read_wrf_nc.f
    Todo:  Move projection stuff into a separate class to allow other
    projections...
    """

    def __init__(self, file_name):

        # Open netcdf file
        self.f = Dataset(file_name)

        # Title
        self.title = getattr(self.f, 'TITLE').strip()

        # Variables
        self.v = self.f.variables

        # Start time for sim
        self.start_date = datetime.datetime.strptime(
                            getattr(self.f, 'START_DATE').strip(),
                            '%Y-%m-%d_%H:%M:%S')

        # Sims times
        self.times = [ self.start_date + datetime.timedelta(hours=_/60.0)
            for _ in np.rint(self.v['XTIME'][:]) ]

        # Check Projection
        if getattr(self.f, 'MAP_PROJ') != 1:
            logging.error('Expecting Lambert Conformal project')
            raise SystemExit

        # WRF mean radius of earth (m)
        self.re = 6370000.0

        # Get necessary projection parameters
        self.stand_lon = center(getattr(self.f, 'STAND_LON'))
        self.truelat1 = getattr(self.f, 'TRUELAT1')
        self.truelat2 = getattr(self.f, 'TRUELAT2')
        self.dx = getattr(self.f, 'DX')
        self.dy = getattr(self.f, 'DY')

        # Latitude and longitude
        self.xlat = self.v['XLAT'][0]
        self.xlon = self.v['XLONG'][0]

        # Shape ni, nj
        self.ni, self.nj = self.xlat.shape[-2], self.xlat.shape[-1]

        # Southwest corner coordinates
        self.knowni = 1
        self.knownj = 1
        self.lat1 = self.xlat[0,0]
        self.lon1 = self.xlon[0,0]

        # Calc hemisphere factor
        self.hemi = np.sign(self.truelat1)

        # Cone
        if self.truelat1 == self.truelat2:
            self.cone = np.sin(np.radians(np.abs(self.truelat1)))
        else:
            self.cone=  ( np.log(np.cos(np.radians(self.truelat1)))
                            - np.log(np.cos(np.radians(self.truelat2))) ) / \
                        ( np.log(np.tan(np.radians(90.0-np.abs(self.truelat1))*0.5))
                            - np.log(np.tan(np.radians(90.0-np.abs(self.truelat2))*0.5)) )

        # Radius to southwest corner
        self.dlon1 = center(self.lon1-self.stand_lon)
        self.rsw = self.re/self.dx * np.cos(np.radians(self.truelat1)) / self.cone * \
                ( np.tan( np.radians(90.0*self.hemi-self.lat1)*0.5) /
                    np.tan( np.radians(90.0*self.hemi-self.truelat1)*0.5) )**self.cone

        # Fine pole point
        self.polei = self.hemi*self.knowni - self.hemi*self.rsw*np.sin(self.cone*np.radians(self.dlon1))
        self.polej = self.hemi*self.knownj + self.rsw*np.cos(self.cone*np.radians(self.dlon1))

    def __repr__(self):
        """
        Just copy Dataset's repr
        """

        return repr(self.f)

    def __str__(self):
        """
        Just copy Dataset's str
        """
        return str(self.f)

    def __enter__(self):
        """
        Allow use of with statement with class.
        """
        return self

    def __exit__(self, *ignored):
        """
        Safely close netcdf file.
        """
        self.f.close()

    def ij2ll(self, i, j):
        """
        Return latitude, longitude given location in grid.
        """
        return self.xlat[i, j], self.xlon[i, j]

    def ll2ij(self, lat, lon):
        """
        Return location in grid given latitude, longitude.
        """

        # Radius to desired point
        rm = self.re/self.dx * np.cos(np.radians(self.truelat1)) / self.cone * \
                (np.tan(np.radians(90.0*self.hemi-lat)*0.5) /
                    np.tan(np.radians(90.0*self.hemi-self.truelat1)*0.5))**self.cone

        # Transformation
        dlon = center(lon - self.stand_lon)

        x = self.polei + self.hemi*rm*np.sin(self.cone*np.radians(dlon))
        y = self.polej - rm*np.cos(self.cone*np.radians(dlon))

        # Return integer
        # ... and correcting for hemisphere (hopefully)
        # ... and switch to zero-indexing
        return np.rint(self.hemi*y).astype(int)-1, np.rint(self.hemi*x).astype(int)-1

    def alpha(self, lat, lon):
        """
        Angle that positive geographical (eastward) x-axis is away from
        positive Lambert x-axis.
        """
        return np.sign(lat)*center(lon-self.stand_lon)*self.cone

    def rotate(self, u, v, lat, lon):
        """
        Rotate Lambert vector onto geographic coordinates
        (u=east/west, v=north/south).
        """

        a = self.alpha(lat, lon)
        cos_alpha = np.cos(np.radians(a))
        sin_alpha = np.sin(np.radians(a))
        return v*sin_alpha+u*cos_alpha, v*cos_alpha-u*sin_alpha

    def extract(self, n, t=slice(None),
                        i=slice(None), j=slice(None), k=slice(None),
                        s=slice(None), c=slice(None)):
        """
        Given variable name n will return a sliced array (and units!).
        t is time, i is south_north, j is west_east, k is bottom_top,
        s is soil_layers, and c is land_cat.
        Defaults are everything i.e. slice(None).
        Can pass intervals as well e.g. i=slice(3,10).
        """

        # Check that key exists
        try:
            v = self.v[n]
        except KeyError:
            print n, 'not found in dataset'
            print 'Available variables:', ",".join(self.v.keys())
            raise

        # Check that units exist; if not, it is a nasty variable like Times
        try:
            units = getattr(v, 'units')
        except AttributeError:
            print n, 'does not have units'
            raise

        # Check that description exists; if not, use name n
        try:
            desc = getattr(v, 'description')
        except AttributeError:
            desc = n

        # Switch our extraction call based on dimensions of named variable
        d = v.dimensions

        if d == (u'Time', u'south_north', u'west_east'):
            # Surface, e.g. T2
            return WRFArray(np.squeeze(v[t, i, j]), units=units, desc=desc)

        elif d == (u'Time', u'bottom_top', u'south_north', u'west_east_stag'):
            # 3D, U-like
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units, desc=desc)

        elif d == (u'Time', u'bottom_top', u'south_north_stag', u'west_east'):
            # 3D, V-like
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units, desc=desc)

        elif d == (u'Time', u'bottom_top_stag', u'south_north', u'west_east'):
            # 3D, W-like
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units, desc=desc)

        elif d == (u'Time', u'bottom_top', u'south_north', u'west_east'):
            # 3D, centered, non-staggered, e.g. TKE
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units, desc=desc)

        elif d == (u'Time', u'soil_layers_stag', u'south_north', u'west_east'):
            # 3D-ish, soil layers, surface
            return WRFArray(np.squeeze(v[t, s, i, j]), units=units, desc=desc)

        elif d == (u'Time', u'bottom_top'):
            # Time, centered vertical, e.g. ZNU {eta values on half (mass) levels}
            return WRFArray(np.squeeze(v[t, k]), units=units, desc=desc)

        elif d == (u'Time', u'bottom_top_stag'):
            # time, staggered vertical, e.g. ZNW {eta values on full (W) levels}
            return WRFArray(np.squeeze(v[t, k]), units=units, desc=desc)

        elif d == (u'Time', u'soil_layers_stag'):
            # time, soil layers, e.g. ZS {soil layer depths}
            return WRFArray(np.squeeze(v[t, s]), units=units, desc=desc)

        elif d == (u'Time', u'south_north_stag', u'west_east'):
            # time, staggered north
            return WRFArray(np.squeeze(v[t, i, j]), units=units, desc=desc)

        elif d == (u'Time', u'south_north', u'west_east_stag'):
            # time, staggered east
            return WRFArray(np.squeeze(v[t, i, j]), units=units, desc=desc)

        elif d == (u'Time',):
            # just boring ol' time
            return WRFArray(np.squeeze(v[t]), units=units, desc=desc)

        elif d == (u'Time', u'land_cat_stag', u'south_north', u'west_east'):
            # land use e.g. LANDUSEF (landuse fraction by category)
            return WRFArray(np.squeeze(v[t, c, i, j]), units=units, desc=desc)

        else:
            print 'Do not understand', d, 'dimensions, sorry...'
            raise SystemExit

def main():


    """
    Read and form time series from a series of WRF EMS runs.
    """

    parser = argparse.ArgumentParser(
        description=main.__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument('domain', help='specify root domain')

    parser_location = parser.add_mutually_exclusive_group(required=True)

    parser_location.add_argument('-ll', dest='ll', metavar=('lat', 'lon'), nargs=2,
        type=float, help='specify lat lon of desired location')

    parser_location.add_argument('-ij', dest='ij', metavar=('i', 'j'), nargs=2,
        type=int, help='specify i and j index of desired location')

    parser.add_argument('-n', '--nest', metavar='int',  type=int,
        help='specify nested domain; will use finest grid available if not supplied')

    parser.add_argument('--spinup', dest='spinup', metavar='hours', default=12,
        type=int, help='specify spin-up time in hours')

    args = parser.parse_args()

    # Point logging to domain.log
    logging.basicConfig(filename='%s.log' % args.domain, level=logging.INFO,
        format='%(asctime)s - %(message)s')

    # Master directory
    domainDir = os.path.join(EMS_RUN, args.domain)

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

    # Loop over all chunks
    for runDir in runDirs:

        print 'De-chunking', runDir

        # Check if it has been run
        wrfFiles = sorted(glob.glob(os.path.join(runDir, 'wrfprd', 'wrfout_d%02d*' % nest)))
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
                ij = (args.ij[0]-1, args.ij[1]-1)

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

            # Screen temperature (2m drybulb)
            # WRF is Kelvin; convert to Celsius
            names.append(u'Drybulb Temperature')
            data.append(np.round(w.extract('T2', i=ij[0], j=ij[1]) - 273.15, decimals=1))
            units.append(u'C')

            # Screen humidity ratio (2m)
            # WRF is kg/kg (dry air); convert to g/kg (dry air)
            names.append(u'Humidity Ratio')
            data.append(np.round(w.extract('Q2', i=ij[0], j=ij[1])*1000., decimals=2))
            units.append(u'g/kg')

            # Screen relative humidity
            # WRF is fraction [0,1]; convert to percentage
            names.append(u'Relative Humidity')
            data.append(np.round(w.extract('RH02', i=ij[0], j=ij[1])*100., decimals=0))
            units.append(u'%')

            # Surface pressure
            # WRF is in Pa
            names.append(u'Surface Pressure')
            data.append(np.round(w.extract('PSFC', i=ij[0], j=ij[1]), decimals=2))
            units.append(u'Pa')

            # 10m winds
            # WRF is vector and aligned with grid; need to rotate 'em
            U10 = w.extract('U10', i=ij[0], j=ij[1])
            V10 = w.extract('V10', i=ij[0], j=ij[1])
            (U10, V10) = w.rotate(U10, V10, ll[0], ll[1])
            # Convert to wind speed; m/s
            names.append(u'Wind Speed')
            data.append(np.round(np.sqrt(U10**2+V10**2), decimals=1))
            units.append(u'm/s')
            # Convert to wind direction; degrees CW from North (azimuth/compass)
            names.append(u'Wind Direction')
            data.append(np.round(np.mod(90 - np.degrees(np.arctan2(-V10, -U10)), 360), decimals=0))
            units.append(u'deg')

            # Shortwave down or Global Horizontal Radiation
            # WRF is instantaneous W/m2
            # We would like W·hr/m² i.e. integrated over previous hour
            # Approximate with average value of current & previous hour
            names.append(u'Global Horizontal Radiation')
            SWDOWN = w.extract('SWDOWN', i=ij[0], j=ij[1])
            SWDOWN[1:] = (SWDOWN[1:] + SWDOWN[0:-1])/2.0
            data.append(np.round(SWDOWN, decimals=0))
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
            data.append(np.round(TACC_SNOW, 3))
            units.append(u'mm')

            # Can easily add more variables at this point
            # e.g. skin temperature in K, converting to C
            #names.append(u'Surface Skin Temperature')
            #data.append(np.round(w.extract('TSK', i=ij[0], j=ij[1])-273.15, decimals=1))
            #units.append(u'C')

            # Print a header... just once
            if header:

                # Form fileName
                fileName = os.path.join(
                    EMS_RUN, '%s_i%02d_j%02d.csv' % (args.domain, ij[0]+1, ij[1]+1)
                )

                # Latitude, Longitude, Elevation
                XLAT = w.extract('XLAT', i=ij[0], j=ij[1], t=0)
                XLON = w.extract('XLONG', i=ij[0], j=ij[1], t=0)
                HGT = w.extract('HGT', i=ij[0], j=ij[1], t=0)

                with open(fileName, 'w') as f:
                    # Write out some information about the location
                    f.write(('# %s %.4f degN %.4f degE %.1f m\n' %
                        (args.domain, XLAT, XLON, HGT)).encode('utf8')
                    )

                    # The variables
                    names = ['Year', 'Month', 'Day', 'Hour'] + names
                    f.write((','.join(names)+'\n').encode('utf8'))

                    # The units
                    units = ['yyyy', 'mm', 'dd', 'hh'] + units
                    f.write((','.join(units)+'\n').encode('utf8'))

                header = False

            # Append data
            with open(fileName, 'a') as f:

                # Loop carefully over all times
                for i, t in enumerate(w.times):

                    # Ignore everything in the spinup period
                    if t <= startDate:
                        continue

                    # Dial time back a smidge so that we can put hours [1,24]
                    t -= datetime.timedelta(seconds=1)

                    # The data
                    datarow = ['%d' % x for x in [t.year, t.month, t.day, (t.hour+1)]]
                    datarow.extend(['%.6g' % data[_][i] for _ in range(len(data))])

                    f.write((','.join(datarow)+'\n').encode('utf8'))

    print 'Wrote to', fileName

if __name__ == "__main__":
    main()
