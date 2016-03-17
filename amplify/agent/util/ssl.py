# -*- coding: utf-8 -*-
import os
import time
import datetime
import re

from amplify.agent.util import subp
from amplify.agent.context import context


__author__ = "Grant Hulegaard"
__copyright__ = "Copyright (C) Nginx, Inc. All rights reserved."
__credits__ = ["Mike Belov", "Andrei Belov", "Ivan Poluyanov", "Oleg Mamontov", "Andrew Alexeev", "Grant Hulegaard"]
__license__ = ""
__maintainer__ = "Grant Hulegaard"
__email__ = "grant.hulegaard@nginx.com"


ssl_regexs = (
    re.compile('.*/C=(?P<country>[\w]+).*'),
    re.compile('.*/ST=(?P<state>[\w\s]+).*'),
    re.compile('.*/L=(?P<location>[\w\s]+).*'),
    re.compile('.*/O=(?P<organization>[\w\s,\'\-\.]+).*'),
    re.compile('.*/OU=(?P<unit>[\w\s,\-\.]+).*'),
    re.compile('.*/CN=(?P<common_name>[\w\s\'\-\.]+).*'),
)


ssl_text_regexs = (
    re.compile('.*Public Key Algorithm: (?P<public_key_algorithm>.*)'),
    re.compile('.*Public-Key: \((?P<length>\d+).*\)'),
    re.compile('.*Signature Algorithm: (?P<signature_algorithm>.*)')
)


ssl_dns_regex = re.compile('DNS:[\w\s\-\.]+')


def certificate_dates(filename):
    keys = {
        'notBefore': 'start',
        'notAfter': 'end'
    }
    results = {}

    openssl_out, _ = subp.call("openssl x509 -in %s -noout -dates" % filename, check=False)
    for line in openssl_out:
        if line:
            key, value = line.split('=')
            if key in keys:
                results[keys[key]] = int(datetime.datetime.strptime(value, '%b %d %H:%M:%S %Y %Z').strftime('%s'))

    return results or None


def certificate_subject(filename):
    results = {}

    openssl_out, _ = subp.call("openssl x509 -in %s -noout -subject" % filename, check=False)
    for line in openssl_out:
        if line:
            for regex in ssl_regexs:
                match_obj = regex.match(line)
                if match_obj:
                    results.update(match_obj.groupdict())

    return results or None


def certificate_issuer(filename):
    results = {}

    openssl_out, _ = subp.call("openssl x509 -in %s -noout -issuer" % filename, check=False)
    for line in openssl_out:
        if line:
            for regex in ssl_regexs:
                match_obj = regex.match(line)
                if match_obj:
                    results.update(match_obj.groupdict())

    return results or None


def certificate_purpose(filename):
    results = {}

    openssl_out, _ = subp.call("openssl x509 -in %s -noout -purpose" % filename, check=False)
    for line in openssl_out:
        if line:
            split = line.split(' : ')
            if len(split) == 2:
                key, value = line.split(' : ')
                results[key] = value

    return results or None


def certificate_ocsp_uri(filename):
    result = None

    openssl_out, _ = subp.call("openssl x509 -in %s -noout -ocsp_uri" % filename, check=False)
    if openssl_out[0]:
        result = openssl_out[0]

    return result


def certificate_full(filename):
    results = {}

    openssl_out, _ = subp.call("openssl x509 -in %s -noout -text" % filename, check=False)
    for line in openssl_out:
        for regex in ssl_text_regexs:
            match_obj = regex.match(line)
            if match_obj:
                results.update(match_obj.groupdict())
                continue  # If a match was made skip the DNS check.

            dns_matches = ssl_dns_regex.findall(line)
            if dns_matches:
                results['names'] = map(lambda x: x.split(':')[1], dns_matches)

    return results or None


def ssl_analysis(filename):
    """
    Get information about SSL certificates found by NginxConfigParser.

    :param filename: String Path/filename
    :return: Dict Information dict about ssl certificate
    """
    results = dict()

    start_time = time.time()
    context.log.info('ssl certificate found %s' % filename)

    # Check if we can open certificate file
    try:
        cert_handler = open(filename, 'r')
        cert_handler.close()
    except IOError:
        context.log.info('could not read %s (maybe permissions?)' % filename)
        return None

    try:
        # Modified date/time
        results['modified'] = int(os.path.getmtime(filename))

        # Certificate dates
        results['dates'] = certificate_dates(filename)

        # Subject information
        results['subject'] = certificate_subject(filename)

        # Issuer information
        results['issuer'] = certificate_issuer(filename)

        # Purpose information
        results['purpose'] = certificate_purpose(filename)

        # OCSP URI
        results['ocsp_uri'] = certificate_ocsp_uri(filename)

        # Domain names, etc
        additional_info = certificate_full(filename)
        if additional_info:
            results.update(additional_info)

        if 'length' in results:
            results['length'] = int(results['length'])

        if results.get('names'):
            if results['subject']['common_name'] not in results['names']:
                results['names'].append(results['subject']['common_name'])  # add subject name
        else:
            results['names'] = [results['subject']['common_name']]  # create a new list of 1
    except Exception as e:
        exception_name = e.__class__.__name__
        message = 'failed to analyze certificate %s due to: %s' % (filename, exception_name)
        context.log.debug(message, exc_info=True)
        return None
    finally:
        end_time = time.time()
        context.log.debug('ssl analysis took %.3f seconds for %s' % (end_time-start_time, filename))

    return results
