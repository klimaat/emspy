#!/usr/bin/env bash
# Tweaks for WRF EMS v3.4.1.14.16 to fix broken NARR configuration
cp -bv Pstart.pm $EMS_STRC/ems_prep/
cp -bv Vtable.NARR $EMS_DATA/tables/vtables/
cp -bv METGRID.TBL.NARR.ARW $EMS_DATA/tables/wps/
cp -bv *_gribinfo.conf $EMS_CONF/grib_info/
