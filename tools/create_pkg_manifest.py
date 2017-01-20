#!/usr/bin/env python
# Copyright 2016 The Dart project authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Usage: create_pkg_manifest.py --deps <DEPS file> --output <jiri manifest>
#
# This script parses the DEPS file, extracts dependencies that live under
# third_party/pkg, and writes them to a file suitable for consumption as a
# jiri manifest for Fuchsia. It is assumed that the Dart tree is under
# //dart in the Fuchsia world, and so the dependencies extracted by this script
# will go under //dart/third_party/pkg.

import argparse
import os
import sys
import utils

SCRIPT_DIR = os.path.dirname(sys.argv[0])
DART_ROOT = os.path.realpath(os.path.join(SCRIPT_DIR, '..'))

# Used in parsing the DEPS file.
class VarImpl(object):
  def __init__(self, local_scope):
    self._local_scope = local_scope

  def Lookup(self, var_name):
    """Implements the Var syntax."""
    if var_name in self._local_scope.get("vars", {}):
      return self._local_scope["vars"][var_name]
    raise Exception("Var is not defined: %s" % var_name)


def ParseDepsFile(deps_file):
  local_scope = {}
  var = VarImpl(local_scope)
  global_scope = {
    'Var': var.Lookup,
    'deps_os': {},
  }
  # Read the content.
  with open(deps_file, 'r') as fp:
    deps_content = fp.read()

  # Eval the content.
  exec(deps_content, global_scope, local_scope)

  # Extract the deps and filter.
  deps = local_scope.get('deps', {})
  filtered_deps = {}
  for k, v in deps.iteritems():
    if 'sdk/third_party/pkg' in k:
      new_key = k.replace('sdk', 'dart', 1)
      filtered_deps[new_key] = v

  return filtered_deps


def WriteManifest(deps, manifest_file):
  project_template = """
    <project name="%s"
             path="%s"
             remote="%s"
             revision="%s"/>
"""
  warning = ('<!-- This file is generated by '
             '//dart/tools/create_pkg_manifest.py. DO NOT EDIT -->\n')
  with open(manifest_file, 'w') as manifest:
    manifest.write(warning)
    manifest.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    manifest.write('<manifest>\n')
    manifest.write('  <projects>\n')
    for path, remote in sorted(deps.iteritems()):
      remote_components = remote.split('@')
      remote_url = remote_components[0]
      remote_version = remote_components[1]
      manifest.write(
          project_template % (path, path, remote_url, remote_version))
    manifest.write('  </projects>\n')
    manifest.write('</manifest>\n')


def ParseArgs(args):
  args = args[1:]
  parser = argparse.ArgumentParser(
      description='A script to generate a jiri manifest for third_party/pkg.')

  parser.add_argument('--deps', '-d',
      type=str,
      help='Input DEPS file.',
      default=os.path.join(DART_ROOT, 'DEPS'))
  parser.add_argument('--output', '-o',
      type=str,
      help='Output jiri manifest.',
      default=os.path.join(DART_ROOT, 'dart_third_party_pkg.manifest'))

  return parser.parse_args(args)


def Main(argv):
  args = ParseArgs(argv)
  deps = ParseDepsFile(args.deps)
  WriteManifest(deps, args.output)
  return 0


if __name__ == '__main__':
  sys.exit(Main(sys.argv))