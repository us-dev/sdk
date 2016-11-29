// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package:expect/expect.dart";
import "package:developer.dart";
import 'test_helper.dart';

var tests = [
  (Isolate isolate){
    var o = new ObjectIdTest();
    var sub = new ObjectIdTest();
    o.subObject = sub;
    String oid = getObjectId(o);
    String subId = getObjectId(sub);
    String isolateId = getIsolateId(isolate);
    Map objectDescriptor = await getObject(isolateId, oid);
    expect(objectDescriptor['class']['name'] == 'ObjectIdTest');

    expect(evaluate(oid, 'i')['valueAsString'] == '42');
    expect(evaluate(oid, 'f')['valueAsString'] == '91');
    expect(evaluate(oid, 's')['valueAsString'] == 'We ID under 42');
    expect(evaluate(oid, 'i')['valueAsString'] == '42');
    expect(evaluate(oid, 'subobject')['id'] == subId);
  }
];



class ObjectIdTest {
  int i = 42;
  float f = 91;
  String s = 'We ID under 42';
  ObjectIdTest subobject;
}


main(args) => runIsolateTests(args, tests); // or is it runVMTests?

main() {
  runIsolateTests(args, tests);
}
