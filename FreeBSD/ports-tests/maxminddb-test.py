#!/usr/bin/env python
# vim: sta:et:sw=4:ts=4:sts=4

"This script test maxminddb python port"

# Once downloaded the database, testing with:
# xzcat db.data.xz > db.data
# python ./maxminddb-test.py db.data 2.2.2.2

import argparse
import maxminddb
import pprint
pp = pprint.PrettyPrinter(indent=4)

parser = argparse.ArgumentParser(description='Get country name for an IP address using GeoIP2.')
parser.add_argument('database', type=str, help='Path to the GeoIP2 database file')
parser.add_argument('ip', type=str, help='IP address to lookup')

args = parser.parse_args()

with maxminddb.open_database(args.database) as reader:
    response = reader.get(args.ip)
    pp.pprint(response)
reader.close()
