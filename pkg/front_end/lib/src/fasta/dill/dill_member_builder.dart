// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.dill_member_builder;

import 'package:kernel/ast.dart' show
    Constructor,
    Field,
    Member,
    Procedure,
    ProcedureKind;

import '../errors.dart' show
    internalError;

import '../kernel/kernel_builder.dart' show
    Builder,
    MemberBuilder;

import '../modifier.dart' show
    abstractMask,
    constMask,
    externalMask,
    finalMask,
    staticMask;

class DillMemberBuilder extends MemberBuilder {
  final int modifiers;

  final Member member;

  final Builder parent;

  DillMemberBuilder(Member member, this.parent)
      : modifiers = computeModifiers(member),
        member = member;

  Member get target => member;

  bool get isConstructor => member is Constructor;

  bool get isFactory {
    if (member is Procedure) {
      Procedure procedure = member;
      return procedure.kind == ProcedureKind.Factory;
    } else {
      return false;
    }
  }
}

int computeModifiers(Member member) {
  int modifier = member.isAbstract ? abstractMask : 0;
  modifier |= member.isExternal ? externalMask : 0;
  if (member is Field) {
    modifier |= member.isConst ? constMask : 0;
    modifier |= member.isFinal ? finalMask : 0;
    modifier |= member.isStatic ? staticMask : 0;
  } else if (member is Procedure) {
    modifier |= member.isConst ? constMask : 0;
    modifier |= member.isStatic ? staticMask : 0;
  } else if (member is Constructor) {
    modifier |= member.isConst ? constMask : 0;
  } else {
    internalError("Unhandled: ${member.runtimeType}");
  }
  return modifier;
}