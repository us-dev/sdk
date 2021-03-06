// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.unhandled_listener;

import '../../scanner/token.dart' show Token;

import 'stack_listener.dart' show NullValue, StackListener;

export 'stack_listener.dart' show NullValue;

// TODO(ahe): Get rid of this.
enum Unhandled {
  ConditionalUri,
  ConditionalUris,
  DottedName,
  Hide,
  Initializers,
  Interpolation,
  Metadata,
  Show,
  TypeVariables,
}

// TODO(ahe): Get rid of this class when all listeners are complete.
abstract class UnhandledListener extends StackListener {
  int popCharOffset() => -1;

  List<String> popIdentifierList(int count) => popList(count);

  @override
  void endMetadataStar(int count, bool forParameter) {
    debugEvent("MetadataStar");
    push(popList(count) ?? NullValue.Metadata);
  }

  @override
  void endConditionalUri(Token ifKeyword, Token equalitySign) {
    debugEvent("ConditionalUri");
    popCharOffset();
    pop(); // URI.
    if (equalitySign != null) popCharOffset();
    popIfNotNull(equalitySign); // String.
    pop(); // DottedName.
    push(Unhandled.ConditionalUri);
  }

  @override
  void endConditionalUris(int count) {
    debugEvent("ConditionalUris");
    popList(count);
    push(Unhandled.ConditionalUris);
  }

  @override
  void endHide(Token hideKeyword) {
    debugEvent("Hide");
    pop();
    push(Unhandled.Hide);
  }

  @override
  void endShow(Token showKeyword) {
    debugEvent("Show");
    pop();
    push(Unhandled.Show);
  }

  @override
  void endCombinators(int count) {
    debugEvent("Combinators");
    push(popList(count) ?? NullValue.Combinators);
  }

  @override
  void endDottedName(int count, Token firstIdentifier) {
    debugEvent("DottedName");
    popIdentifierList(count);
    push(Unhandled.DottedName);
  }

  @override
  void handleFunctionType(Token functionToken, Token endToken) {
    pop(); // Formals.
    pop(); // Type variables.
    pop(); // Return type.
    push(NullValue.Type);
  }

  @override
  void prepareInitializers() {
    debugEvent("prepareInitializers");
  }
}
