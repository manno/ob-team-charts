#!/usr/bin/env python3
"""Print `export IMAGE_*=repo:tag` lines from a rendered chart's values.yaml.

Used by the verify job so the smoke test exercises exactly the images baked
into the freshly-rendered chart (rather than the script's hard-coded defaults).

Usage: eval "$(python3 derive-images.py charts/.../values.yaml)"
"""
import sys
import yaml


def main():
    values = yaml.safe_load(open(sys.argv[1]))
    img = values['image']
    imgs = values['images']

    def emit(name, block):
        print(f'export {name}="{block["repository"]}:{block["tag"]}"')

    print(f'export IMAGE_LOGGING_OPERATOR="{img["repository"]}:{img["tag"]}"')
    emit('IMAGE_CONFIG_RELOADER', imgs['config_reloader'])
    emit('IMAGE_FLUENT_BIT', imgs['fluentbit'])
    emit('IMAGE_FLUENTD', imgs['fluentd'])


if __name__ == '__main__':
    main()
