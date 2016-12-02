// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package:expect/expect.dart";
import "package:developer.dart";
import 'test_helper.dart';

// run on 'host'.
var tests = [
  hasStoppedAtBreakpoint,
  (Isolate isolate) async {
    var instance = await isolate.evaluate('() => myId');
    expect(instance is Map);
    var ival = instance['valueAsString'];
    expect(ival == "My One True Object");  
  }
];


// running on 'device'.
// global variables

String myId;

testeeMain() {
  String o = "My One True Object";
  myId = getObjectId(o);
  debugger();
}

// Run on 'host'.
main(args) => runIsolateTests(args, testeeMain: testeeMain); 