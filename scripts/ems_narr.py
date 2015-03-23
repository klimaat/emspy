#!/usr/bin/env python
import os, argparse, subprocess, calendar

if __name__ == "__main__":

    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Download NARR files',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter  
    )

    parser.add_argument('-l', '--limit', type=int, metavar='kbps', help='speed limit kbps')
    parser.add_argument('-q', '--quiet', action='store_true', help='quiet mode')
    parser.add_argument('-y', '--year', type=int, nargs='+', metavar='year', help='specify year')
    parser.add_argument('-m', '--month', type=int, nargs='+', metavar='month', help='specify month')
    
    args = parser.parse_args()

    # We'll only download specific year(s)
    if args.year:
        years = args.year
    else:
        years = range(1979,2015+1)  
        
    # We'll only download a specific month
    if args.month:
        months = args.month
    else:
        months = range(1,13)

    # Use wget to handle the downloading
    wget = 'wget '
    
    # ... and turn on timestamping so that we only download new versions
    wget +='--timestamping '
    
    # Limit to arg.limits kbps
    if args.limit is not None:
        wget += '--limit-rate=%dk ' % args.limit
    
    # Turn off progress bar (especially if you run this under nohup)
    if args.quiet:
        wget += '--no-verbose '
    
    #http://soostrc.comet.ucar.edu/data/grib/narr/1979/01/narr-a_221_19790101_0000_000.grb2
    
    # Release the hounds!
    for year in years:
        
        for month in months:
            
            nDaysInMonth = calendar.monthrange(year, month)[1]
            days = range(1, nDaysInMonth+1)

            for day in days:
                
                for hour in [0, 3, 6, 9, 12, 15, 18, 21]:
                    
                    dn = '%04d/%02d' % (year, month)
                    fn = 'narr-a_221_%04d%02d%02d_%02d00_000.grb2' % (year, month, day, hour)

                    cmd = wget + '--directory-prefix=%4s ' % dn
                    cmd +=  'http://soostrc.comet.ucar.edu/data/grib/narr/%s/%s' % (dn, fn)
                    
                    subprocess.call([cmd], shell=True)
                    
                
