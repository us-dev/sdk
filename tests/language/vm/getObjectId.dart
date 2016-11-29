// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "package:expect/expect.dart";
import "package:developer.dart";
import 'package:vm_service_client/vm_service_client.dart';


class ObjectIdTest {
  int i = 42;
  float f = 91;
  String s = 'We ID under 42';
  ObjectIdTest subobject;
}

main() {

  VMServiceCkient client = VMServiceClient.connect(url); // ok, how do we do this?
  VM vm = await client.getVM();
  VMIsolate isolate = vm.isolates.first;

  Scope scope = isolate.scope;
  var o = new ObjectIdTest();
  var sub = new ObjectIdTest();
  o.subObject = sub;
  var id = getObjectId(o);
  var cid = getObjectId(ObjectIdTest);
  Map m = {
    'type': 'Instance',
    'id':id,
    'class': {
      'type': 'Class',
      'id': cid,
      'name': 'ObjectIdTest'
    }
  };
  
  VMInstanceRef oRef = new VMInstanceRef(scope, m);
  
  VMObject oMirror = oRef.load();
  VMClassRef cRef = oMirror.klass;
  VMClass cMirror = await cRef.load();
  expect(cMirror.name = 'ObjectIdTest');
  Map<String, VMFieldRef> fs = cMirror.fields;
  VMFieldRef idI = fs['i']);
  expect(idI = 42);
}
