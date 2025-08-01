#!/usr/bin/env python
# vim: sta:et:sw=4:ts=4:sts=4

"This script test geoip2 python port"

# Once downloaded the database, testing with:
# xzcat db.data.xz > db.data
# python ./geoip.test.py db.data 2.2.2.2
# Country for 2.2.2.2 is Sweden

import argparse
import geoip2.database

parser = argparse.ArgumentParser(description='Get country name for an IP address using GeoIP2.')
parser.add_argument('database', type=str, help='Path to the GeoIP2 database file')
parser.add_argument('ip', type=str, help='IP address to lookup')

args = parser.parse_args()

geo = geoip2.database.Reader(args.database)

response = geo.country(args.ip)
print(f"Country for {args.ip} is {response.country.name}")
geo.close()
