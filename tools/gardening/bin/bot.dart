// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'compare_failures.dart' as compare_failures;
import 'current_summary.dart' as current_summary;
import 'status_summary.dart' as status_summary;

typedef Future MainFunction(List<String> args);

help(List<String> args) async {
  if (args.length == 1 && args[0] == "--help") {
    print("This help");
    return null;
  }

  print("A script that combines multiple commands:\n");

  for (String command in commands.keys) {
    print(command);
    print('-' * command.length);
    await commands[command](["--help"]);
    print("");
  }
}

const Map<String, MainFunction> commands = const <String, MainFunction>{
  "help": help,
  "compare-failures": compare_failures.main,
  "current-summary": current_summary.main,
  "status-summary": status_summary.main,
};

main(List<String> args) async {
  if (args.isEmpty) {
    await help([]);
    exit(-1);
  }
  var command = commands[args[0]];
  if (command == null) {
    await help([]);
    exit(-1);
  }
  command(args.sublist(1));
}
