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
    ServiceInstance instance = await isolate.evaluate('() => myHeader');
    expect(instance is Map);

    String oid = instance['id'];
    var ival = await isolate.vm.evaluate(oid, 'i');
    expect(ival['valueAsString'] == '42');
    var fval = await isolate.vm.evaluate(oid, 'f');
    expect(fval['valueAsString'] == '91');
    var sval = await isolate.vm.evaluate(oid, 's');
    expect(sval['valueAsString'] == 'We ID under 42');    
  
    Map objectDescriptor = await getObject(isolateId, oid);

    ServiceInstance subInstance = await isolate.evaluate('() => subHeader');
    expect(subInstance is Map);
    String subId = subInstance['id'];
    expect(evaluate(subId, 'subobject')['id'] == subId);
    
    String nullId = getObjectId(null);
    expect(evaluate(subId, 'subobject') == null);    
  }
];



class ObjectIdTest {
  int i = 42;
  float f = 91;
  String s = 'We ID under 42';
  ObjectIdTest subobject;
}



// running on 'device'.
// global variables

Map<String, dynamic> myHeader;
Map<String, dynamic> subHeader;
Map<String, dynamic> nullHeader = getServiceObjectDescriptor(null);

testeeMain() {
  ObjectIdTest o = new ObjectIdTest();
  ObjectIdTest sub = new ObjectIdTest();
  o.subObject = sub;
  myHeader = getServiceObjectDescriptor(o);
  subHeader = getServiceObjectDescriptor(sub);
  debugger();
}

// Run on 'host'.
main(args) => runIsolateTests(args, testeeMain: testeeMain); // or is it runVMTests?