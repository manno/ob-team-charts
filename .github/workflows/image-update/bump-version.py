#!/usr/bin/env python3
"""Bump the -suseN chart version in package.yaml.

Strips any existing -suseN suffix, increments the rancher.N number, and
re-adds -suse1. Deterministic and idempotent-per-input: running it once
against a given starting file always yields the same result. The gate's
reproducibility check relies on that, so keep it free of timestamps/randomness.
"""
import re

PKG_FILE = 'packages/rancher-logging/4.10/package.yaml'


def main():
    with open(PKG_FILE) as f:
        content = f.read()

    m = re.search(r'^version:\s+(\S+)', content, re.MULTILINE)
    version = m.group(1)
    version = re.sub(r'-suse\d+$', '', version)
    version = re.sub(r'(rancher\.)(\d+)',
                     lambda mm: mm.group(1) + str(int(mm.group(2)) + 1),
                     version)
    version += '-suse1'
    content = re.sub(r'^version:.*$', f'version: {version}', content,
                     flags=re.MULTILINE)

    with open(PKG_FILE, 'w') as f:
        f.write(content)

    print(f'Version -> {version}')


if __name__ == '__main__':
    main()
