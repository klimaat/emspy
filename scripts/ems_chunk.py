#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import glob
import argparse
import datetime
import logging

from emspy.chunk import ems_run_dir, ems_clean, ems_update, ems_conf, ems_index, ems_clone, ems_prep, ems_run


if __name__ == "__main__":
    
    parser = argparse.ArgumentParser(
        description="Take an existing WRF EMS domain, prep, and run in chunks",
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

    parser.add_argument('-d', '--dset', default='cfsr',
        help='specify dataset', choices=['cfsr', 'narr', 'cfsrptile', 'narrptile'] )
    
    parser.add_argument('-n', '--nest', metavar='int',  type=int, 
        help='specify how many nests to use; will use all available if not supplied')
        
    parser.add_argument('--nodes', type=int,
        help='specify number of nodes')
        
    parser.add_argument('--spinup', metavar='hours', default=12,
        type=int, help='specify spin-up time in hours; should be a multiple of 3 (narr) or 6 (cfsr); frankly, best to leave this alone')
        
    parser.add_argument('--levels', metavar='int', default=45,
        type=int, help='specify number of vertical levels/layers')
        
    parser.add_argument('--nfs', action='store_true',
        help='use local downloaded files')

    args = parser.parse_args()    

    # Point logging to domain.log
    logging.basicConfig(filename='%s.log' % args.domain, level=logging.INFO, 
        format='%(asctime)s - %(message)s')
    
    # Master directory
    domainDir = '%s/%s' % (ems_run_dir(), args.domain)
    
    # Check to see that we have a master root domain directory
    if not os.path.isdir(domainDir):
        print 'ERROR:  Make sure %s exists' % args.domain
        raise SystemExit    
    
    # Override NFS if a tiled dataset selected
    if 'tile' in args.dset:
        if args.nfs:
            print 'WARNING:  Overriding desire to use NFS for', args.dset
            args.nfs = False
            
    # Sanitize and re-localize the directory, just to be sure;
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

    # Adjust frequency of output to 60 minutes
    ems_conf('HISTORY_INTERVAL', 60, '%s/conf/ems_run/run_wrfout.conf' % domainDir)
    
    # All hour frames will clumped into one file
    ems_conf('FRAMES_PER_OUTFILE', 999, '%s/conf/ems_run/run_wrfout.conf' % domainDir)
    
    # Adjust number of vertical levels; default is 45
    ems_conf('LEVELS', args.levels, '%s/conf/ems_run/run_levels.conf' % domainDir)
    
    # Adjust the pressure of the topmost level if NARR
    if 'narr' in args.dset:
        ems_conf('PTOP', 10000, '%s/conf/ems_run/run_levels.conf' % domainDir)
    
    # Adjust cumulus scheme 
    # Use Kain-Fritsch only on domains with >= 10km i.e. d01 & d02
    # Use no cumulus schemes for d03, d04
    ems_conf('CU_PHYSICS', ','.join( [str(_) for _ in [1,1,0,0][0:nDomains]]), 
        '%s/conf/ems_run/run_physics.conf' % domainDir)

    # Adjust microphysics scheme
    # Use Lin et al. scheme
    ems_conf('MP_PHYSICS', 6, '%s/conf/ems_run/run_physics.conf' % domainDir)
    
    # Adjust surface layer scheme
    # Use Monin-Obukhov similarity theory
    ems_conf('SF_SFCLAY_PHYSICS', 1, '%s/conf/ems_run/run_physics.conf' % domainDir)
    
    # Set spin-up time
    spinupHours = args.spinup

    # Convert input dates to datetime objects
    startDate = datetime.datetime.strptime(args.start_date, '%Y%m%d')
    endDate = datetime.datetime.strptime(args.end_date, '%Y%m%d')

    # Iteration over all chunks
    d = startDate
    while d < endDate:

        # Determine chunk id, start, end, and length
        chunkIndex, chunkSpinupDate, chunkStartDate, chunkEndDate, chunkHours = ems_index(d, spinupHours=spinupHours)

        # Create a run directory name
        runDir = '%s/%s_%04d%02d%02d' % (ems_run_dir(), args.domain, 
            chunkStartDate.year, chunkStartDate.month, chunkStartDate.day)

        # Clone master (if needed)
        ems_clone(domainDir, runDir, ignore=('*.jpg',), force=args.force)
        
        # Prep (if needed)
        ems_prep(runDir, chunkSpinupDate, dset=args.dset, length=chunkHours, nDomains=nDomains, 
            cycle=24-spinupHours, nudge=True, nfs=args.nfs, force=args.force)
        
        # Run (if needed)
        if args.skiprun:
            logging.info("NOT running %s; skipping" % runDir)            
        else:
            ems_run(runDir, nDomains=nDomains, nudge=True, nodes=args.nodes, 
                force=args.force)
        
        # Move the sticks
        d = chunkEndDate
        

    
