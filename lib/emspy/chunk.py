# -*- coding: utf-8 -*-
import os
import sys
import datetime
import shutil
import errno
import subprocess
import glob
import re
import logging

    
def ems_run_dir():
    """
    Return the EMS_RUN environment variable
    """
    try:
        return os.environ['EMS_RUN']
    except KeyError:
        logging.error('EMS_RUN does not exist.  Have you installed WRF EMS?')
        raise SystemExit
    
    
def ems_conf(key, val, path):
    """
    Modify conf files.
    """
    cmd = ['sed']
    cmd.append('-i')
    cmd.append(r'"s/^[ \t]*%s.*/%s = %s/"' % (key, key, str(val)))
    cmd.append(path)
    logging.info('Modifying %s = %s' % (key, str(val)))
    return subprocess.call(' '.join(cmd), shell=True) == 0

def ems_clone(src, dest, ignore=(), force=False):
    """
    Clone source, ignoring any glob'd files.
    e.g. ignore=('*.jpg', '*.png')
    """
    
    if force:
        shutil.rmtree(dest, ignore_errors=True)
        
    try:
        shutil.copytree(src, dest, ignore=shutil.ignore_patterns(*ignore))
        logging.info('Copying %s to %s' % (src, dest))
    except OSError as e:
        if e.errno == errno.ENOTDIR:
            shutil.copy(src, dest)
        elif e.errno == errno.EEXIST:
            logging.info('NOT copying %s; already exists; use the force Luke' % (src))
        else:
            logging.error('Directory not copied. Error: %s' % e)
            raise SystemError
            
    except Exception as e:
        raise SystemError


def ems_clean(domainDir, level=0):
    """
    Wrapper to call ems_clean
    """
    cmd = ['ems_clean']
    cmd.append('--level %d' % level)
    logging.info('Cleaning %s' % (domainDir))
    return subprocess.call(' '.join(cmd), shell=True, cwd=domainDir) == 0
                

def ems_update(domainDir):
    """
    Wrapper to call ems_domain.pl --update
    """
    cmd = ['ems_domain.pl']
    cmd.append('--update')
    logging.info('Updating %s' % (domainDir))
    return subprocess.call(' '.join(cmd), shell=True, cwd=domainDir) == 0


def ems_index(d, chunkDays=3, spinupHours=12):
    """
    Given a datetime, return the chunk index and corresponding start and end datetimes 
    for that chunk.  
    Also return the chunk length in hours.  
    Chunks are ideally three days in length but can (maybe) be set to any integer.
    A spin-up time in hours is prepended to the start datetime.
    """
    
    # Year
    y = d.timetuple().tm_year
    
    # This will give the day of the year (1-366), assuming a 366-day year
    n = d.replace(year=2000).timetuple().tm_yday
    
    # This will determine the chunk it is in (0-121)
    index = (n-1)/chunkDays
    
    # This will determine the starting date of the chunk, assuming a 366-day year
    chunkTimedelta = datetime.timedelta(days=chunkDays)
    startDate = datetime.datetime(2000,1,1) + index*chunkTimedelta
    endDate = datetime.datetime(2000,1,1) + (index+1)*chunkTimedelta
    
    # Move back into desired year
    startDate = startDate.replace(year=y)
    endDate = endDate.replace(year=y)
    
    # Check if endDate should be pushed into new year (and cap at the New Year)
    if startDate > endDate:
        endDate = endDate.replace(year=y+1, month=1, day=1)
    
    # Calculate spin-up time 
    spinupTimedelta = datetime.timedelta(hours=spinupHours)
    spinupDate = startDate - spinupTimedelta
    
    # Get total simulation length in hours
    hours = int((endDate-spinupDate).total_seconds()/3600)

    # Should be spinupHours+chunkDays*24, except for Feb 27-Mar 1 chunk on a leap year
    #assert(hours == spinupHours+chunkDays*24)

    logging.info('Chunking #%d %s to %s' % (index, startDate, endDate))
    
    return index, spinupDate, startDate, endDate, hours


def ems_prep(runDir, date, nDomains=3, dset='cfsr', length=84, cycle=12, nudge=True, nfs=False, force=False):
    """
    Run ems_prep.pl with all proper gravitas.
    """
    
    # Check if metgrid files already exist.  If so, skip prep
    if not force:
        met = glob.glob('%s/wpsprd/met*.nc' % runDir)
        if len(met) > 0:
            logging.info("NOT prepping %s; use the force Luke" % runDir)
            return True

    cmd = ['ems_prep.pl']
    cmd.append('--domain %s' % ','.join([str(_) for _ in range(1,nDomains+1)]))
    if nfs:
        cmd.append('--dset %s:nfs' % dset)
    else:
        cmd.append('--dset %s' % dset)
        
    cmd.append('--length %d' % length)
    cmd.append('--analysis')
    cmd.append('--date %04d%02d%02d' % (date.year, date.month, date.day))
    cmd.append('--cycle %02d' % cycle)
    
    if nudge:
        cmd.append('--nudge')

    logging.info("Prepping %s" % runDir)
        
    return subprocess.call(' '.join(cmd), shell=True, cwd=runDir) == 0

    
def ems_run(runDir, nDomains=3, nudge=True, nodes=None, force=False):
    """
    Run ems_run.pl with all proper gravitas.
    """
    
    # Check if wrfout files already exist.  If so, skip run
    if not force:
        wrf = glob.glob('%s/wrfprd/wrfout*' % runDir)
        if len(wrf) > 0:
            logging.info("NOT running %s; use the force Luke" % runDir)
            return True
            
    cmd = ['ems_run.pl']
    cmd.append('--domain %s' % ','.join([str(_) for _ in range(1,nDomains+1)]))
    
    if nodes:
        cmd.append('--nodes %d' % nodes)
        
    if nudge:
        cmd.append('--nudge')
        
    logging.info("Running %s" % runDir)
        
    return subprocess.call(' '.join(cmd), shell=True, cwd=runDir) == 0


if __name__ == "__main__":
    
    pass
    
