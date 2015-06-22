# -*- coding: utf-8 -*-
import numpy as np
from netCDF4 import Dataset
import logging
import datetime


def center(longitude):
    """
    Ensure longitude is within -180 to +180
    """
    return ((longitude + 180.0) % 360) - 180.0


class WRFArray(np.ndarray):
    """
    Subclass numpy ndarray to include units attribute
    """

    def __new__(cls, input_array, units=None):
        obj = np.asarray(input_array).view(cls)
        return obj

    def __init__(self, input_array, units=None):
        self.units = units


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

        i = self.polei + self.hemi*rm*np.sin(self.cone*np.radians(dlon))
        j = self.polej - rm*np.cos(self.cone*np.radians(dlon))

        # Return integer
        # ... and correcting for hemisphere (hopefully)
        # ... and switch to zero-indexing
        return np.rint(self.hemi*i).astype(int)-1, np.rint(self.hemi*j).astype(int)-1

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
            raise SystemExit

        # Check that units exist; if not, it is a nasty variable like Times
        try:
            units = getattr(v, 'units')
        except AttributeError:
            print n, 'does not have units'
            raise SystemExit

        # Switch our extraction call based on dimensions of named variable
        d = v.dimensions

        if d == (u'Time', u'south_north', u'west_east'):
            # Surface, e.g. T2
            return WRFArray(np.squeeze(v[t, i, j]), units=units)

        elif d == (u'Time', u'bottom_top', u'south_north', u'west_east_stag'):
            # 3D, U-like
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units)

        elif d == (u'Time', u'bottom_top', u'south_north_stag', u'west_east'):
            # 3D, V-like
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units)

        elif d == (u'Time', u'bottom_top_stag', u'south_north', u'west_east'):
            # 3D, W-like
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units)

        elif d == (u'Time', u'bottom_top', u'south_north', u'west_east'):
            # 3D, centered, non-staggered, e.g. TKE
            return WRFArray(np.squeeze(v[t, k, i, j]), units=units)

        elif d == (u'Time', u'soil_layers_stag', u'south_north', u'west_east'):
            # 3D-ish, soil layers, surface
            return WRFArray(np.squeeze(v[t, s, i, j]), units=units)

        elif d == (u'Time', u'bottom_top'):
            # Time, centered vertical, e.g. ZNU {eta values on half (mass) levels}
            return WRFArray(np.squeeze(v[t, k]), units=units)

        elif d == (u'Time', u'bottom_top_stag'):
            # time, staggered vertical, e.g. ZNW {eta values on full (W) levels}
            return WRFArray(np.squeeze(v[t, k]), units=units)

        elif d == (u'Time', u'soil_layers_stag'):
            # time, soil layers, e.g. ZS {soil layer depths}
            return WRFArray(np.squeeze(v[t, s]), units=units)

        elif d == (u'Time', u'south_north_stag', u'west_east'):
            # time, staggered north
            return WRFArray(np.squeeze(v[t, i, j]), units=units)

        elif d == (u'Time', u'south_north', u'west_east_stag'):
            # time, staggered east
            return WRFArray(np.squeeze(v[t, i, j]), units=units)

        elif d == (u'Time',):
            # just boring ol' time
            return WRFArray(np.squeeze(v[t]), units=units)

        elif d == (u'Time', u'land_cat_stag', u'south_north', u'west_east'):
            # land use e.g. LANDUSEF (landuse fraction by category)
            return WRFArray(np.squeeze(v[t, c, i, j]), units=units)

        else:
            print 'Do not understand', d, 'dimensions, sorry...'
            raise SystemExit


if __name__ == "__main__":
    pass
