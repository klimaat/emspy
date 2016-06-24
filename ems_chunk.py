#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import glob
import argparse
import datetime
import logging
import shutil
import errno
import subprocess

# Establish EMS_RUN
try:
    EMS_RUN = os.environ['EMS_RUN']
except KeyError:
    logging.error('EMS_RUN does not exist.  Have you installed WRF EMS?')
    raise


def ems_run_dir():
    """
    Return the EMS_RUN environment variable
    """
    try:
        return os.environ['EMS_RUN']
    except KeyError:
        logging.error('EMS_RUN does not exist.  Have you installed WRF EMS?')
        raise SystemExit


def ems_conf(domain, conf, key, val):
    """
    Modify conf files.
    """
    path = os.path.join(domain, 'conf', 'ems_run', 'run_' + conf + '.conf')

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
    startDate = datetime.datetime(2000, 1, 1) + index*chunkTimedelta
    endDate = datetime.datetime(2000, 1, 1) + (index+1)*chunkTimedelta

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

    return {
        'index': index,
        'spinupDate': spinupDate,
        'startDate': startDate,
        'endDate': endDate,
        'hours': hours
    }


def ems_prep(runDir, date, nDomains=3, dset='cfsr', length=84, cycle=12, nudge=True, nfs=False, force=False):
    """
    Run ems_prep.pl with great excitement.
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
    cmd.append('--domain %s' % ','.join([str(_) for _ in range(1, nDomains+1)]))

    if nodes:
        cmd.append('--nodes %d' % nodes)

    if nudge:
        cmd.append('--nudge')

    logging.info("Running %s" % runDir)

    return subprocess.call(' '.join(cmd), shell=True, cwd=runDir) == 0

def main():

    """
    Take an existing WRF EMS domain, prep, and run in chunks
    """

    parser = argparse.ArgumentParser(
        description=main.__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )

    parser.add_argument('domain',
        help='specify master localized domain directory')

    parser.add_argument('start_date',
        help='specify starting YYYYMMDD')

    parser.add_argument('end_date',
        help='specify ending date YYYYMMDD')

    parser.add_argument('-f', '--force', action='store_true',
        help='force cleaning, copying, prep and run')

    parser.add_argument('-s', '--skiprun', action='store_true',
        help='skip running ignoring force')

    parser.add_argument('-d', '--dset', default='cfsrpt',
        help='specify dataset', choices=['cfsrpt', 'narrpt'])

    parser.add_argument('-n', '--nest', metavar='int', type=int,
        help='specify how many nests to use; will use all available if not supplied')

    parser.add_argument('--nodes', type=int,
        help='specify number of nodes/processes; will use all CPUs available if not supplied')

    #~ parser.add_argument('--spinup', metavar='hours', default=12,
        #~ type=int, help='specify spin-up time in hours')

    parser.add_argument('--levels', metavar='int', default=45,
        type=int, help='specify number of vertical levels/layers')

    #~ parser.add_argument('--nfs', action='store_true',
        #~ help='use local downloaded files')

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

    # Override NFS if a tiled dataset selected
    #~ if 'tile' in args.dset:
        #~ if args.nfs:
            #~ print 'WARNING:  Overriding desire to use NFS for', args.dset
            #~ args.nfs = False

    # Sanitize and re-localize the directory, just to be sure;
    if args.force:
        if not ems_clean(domainDir, level=6):
            print 'ERROR: problem sanitizing %s' % domainDir
            raise SystemExit

    # Update the config files; they can get (easily) corrupted
    if not ems_update(domainDir):
        print 'ERROR: updating config files' % domainDir
        raise SystemExit

    # Figure out the number of domains
    geo = glob.glob('%s/static/geo*.nc' % domainDir)
    nDomains = len(geo)

    # Check that it has been localized and ready to run
    if nDomains == 0:
        print 'ERROR: %s was not localized properly.' % args.domain
        raise SystemExit

    # Determine how many domains to use
    if args.nest:
        # Check if requested nest exists
        if args.nest > nDomains:
            print 'ERROR: Requested nest %d not available.' % args.nest
            raise SystemExit
        nDomains = args.nest

    # Adjust frequency of output to hourly (60 minutes)
    ems_conf(domainDir, 'wrfout', 'HISTORY_INTERVAL', 60)

    # All hour frames will clumped into one file
    ems_conf(domainDir, 'wrfout', 'FRAMES_PER_OUTFILE', 999)

    # Adjust number of vertical levels; default is 45
    ems_conf(domainDir, 'levels', 'LEVELS', args.levels)

    # Adjust the pressure of the topmost level if NARR
    if 'narr' in args.dset:
        ems_conf(domainDir, 'levels', 'PTOP', 10000)

    # Adjust cumulus scheme
    # Use Kain-Fritsch only on domains with >= 10km i.e. d01 & d02
    # Use no cumulus schemes for d03, d04
    domain_str = ','.join([str(d) for d in [1, 1, 0, 0][0:nDomains]])
    ems_conf(domainDir, 'physics', 'CU_PHYSICS', domain_str)

    # Adjust microphysics scheme
    # Use Lin et al. scheme
    ems_conf(domainDir, 'physics', 'MP_PHYSICS', 6)

    # Adjust surface layer scheme
    # Use Monin-Obukhov similarity theory
    ems_conf(domainDir, 'physics', 'SF_SFCLAY_PHYSICS', 1)

    # Adjust LW & RW schemes TO RRTMG and
    # Add monthly/latitudinal CAM ozone profiles
    # TODO:  Add aerosol options
    #~ ems_conf(domainDir, 'physics', 'RA_LW_PHYSICS', 24)
    #~ ems_conf(domainDir, 'physics', 'RA_SW_PHYSICS', 24)
    #~ ems_conf(domainDir, 'physics', 'O3_INPUT', 2)

    # Set spin-up time
    #spinupHours = args.spinup
    spinupHours = 12

    # Convert input dates to datetime objects
    startDate = datetime.datetime.strptime(args.start_date, '%Y%m%d')
    endDate = datetime.datetime.strptime(args.end_date, '%Y%m%d')

    # Iteration over all chunks
    d = startDate
    while d < endDate:

        # Determine chunk id, start, end, and length
        chunk = ems_index(d, spinupHours=spinupHours)

        # Create a run directory name
        runDir = os.path.join(EMS_RUN, '%s_%04d%02d%02d' % (
            args.domain, chunk['startDate'].year, chunk['startDate'].month,
            chunk['startDate'].day
        ))

        # Clone master (if needed)
        ems_clone(domainDir, runDir, ignore=('*.jpg',), force=args.force)

        # Prep (if needed)
        ems_prep(runDir, chunk['spinupDate'], dset=args.dset,
                 length=chunk['hours'], nDomains=nDomains,
                 cycle=24-spinupHours, nudge=True,
                 force=args.force)

        # Run (if needed)
        if args.skiprun:
            logging.info("NOT running %s; skipping" % runDir)
        else:
            ems_run(runDir, nDomains=nDomains, nudge=True, nodes=args.nodes,
                    force=args.force)

        # Move the sticks
        d = chunk['endDate']


if __name__ == "__main__":
    main()
