#!/usr/bin/env python3
"""Rewrite a component's image tag in values.yaml.patch.

Reads COMPONENT and TAG from the environment. Deterministic: given the same
starting file + COMPONENT + TAG it always produces byte-identical output. The
gate's reproducibility check (image-update.yaml) relies on that property, so
keep this side-effect-free and do not introduce timestamps/randomness.

For the one-time fluentd migration it also rewrites the mirrored-image repo
string to the SUSE repo on the same line.
"""
import re
import os
import sys

PATCH_FILE = 'packages/rancher-logging/4.10/generated-changes/patch/values.yaml.patch'

REPO_MAP = {
    'logging-operator': 'ghcr.io/manno/logging-operator',
    'config-reloader':  'ghcr.io/manno/config-reloader',
    'fluent-bit':       'ghcr.io/manno/fluent-bit',
    'fluentd':          'ghcr.io/manno/fluentd',
}
# Upstream mirror repos we're migrating away from on first dispatch.
MIGRATE_FROM = {
    'fluentd': 'rancher/mirrored-kube-logging-fluentd',
}


def main():
    component = os.environ['COMPONENT']
    tag = os.environ['TAG']

    repo = REPO_MAP.get(component)
    if not repo:
        print(f'Unknown component: {component}', file=sys.stderr)
        sys.exit(1)

    alias = MIGRATE_FROM.get(component)

    with open(PATCH_FILE) as f:
        lines = f.readlines()

    new_lines = []
    update_next = False
    for line in lines:
        if update_next:
            if re.match(r'\+\s+tag:', line):
                line = re.sub(r'(\+\s+tag:\s+)\S+', rf'\g<1>{tag}', line)
            update_next = False
        if repo in line or (alias and alias in line):
            if alias and alias in line:
                line = line.replace(alias, repo)
            update_next = True
        new_lines.append(line)

    with open(PATCH_FILE, 'w') as f:
        f.writelines(new_lines)

    print(f'Updated {component} -> {tag}')


if __name__ == '__main__':
    main()
