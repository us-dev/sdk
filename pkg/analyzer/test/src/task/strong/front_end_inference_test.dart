// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:front_end/src/base/instrumentation.dart' as fasta;
import 'package:front_end/src/fasta/compiler_context.dart' as fasta;
import 'package:front_end/src/fasta/testing/validating_instrumentation.dart'
    as fasta;
import 'package:front_end/src/fasta/util/relativize.dart' show relativizeUri;
import 'package:kernel/kernel.dart' as fasta;
import 'package:path/path.dart' as pathos;
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../../dart/analysis/base.dart';

main() {
  // Use a group() wrapper to specify the timeout.
  group('front_end_inference_test', () {
    defineReflectiveSuite(() {
      defineReflectiveTests(RunFrontEndInferenceTest);
    });
  }, timeout: new Timeout(const Duration(seconds: 120)));
}

/// Set this to `true` to cause expectation comments to be updated.
const bool fixProblems = false;

@reflectiveTest
class RunFrontEndInferenceTest {
  test_run() async {
    String pkgPath = _findPkgRoot();
    String fePath = pathos.join(pkgPath, 'front_end', 'testcases', 'inference');
    List<File> dartFiles = new Directory(fePath)
        .listSync()
        .where((entry) => entry is File && entry.path.endsWith('.dart'))
        .map((entry) => entry as File)
        .toList();

    var allProblems = new StringBuffer();
    for (File file in dartFiles) {
      var test = new _FrontEndInferenceTest();
      await test.setUp();
      try {
        String code = file.readAsStringSync();
        String problems = await test.runTest(file.path, code);
        if (problems != null) {
          allProblems.writeln(problems);
        }
      } finally {
        await test.tearDown();
      }
    }
    if (allProblems.isNotEmpty) {
      fail(allProblems.toString());
    }
  }

  /**
   * Expects that the [Platform.script] is a test inside of `pkg/analyzer/test`
   * folder, and return the absolute path of the `pkg` folder.
   */
  String _findPkgRoot() {
    String scriptPath = pathos.fromUri(Platform.script);
    List<String> parts = pathos.split(scriptPath);
    for (int i = 0; i < parts.length - 2; i++) {
      if (parts[i] == 'pkg' &&
          parts[i + 1] == 'analyzer' &&
          parts[i + 2] == 'test') {
        return pathos.joinAll(parts.sublist(0, i + 1));
      }
    }
    throw new StateError('Unable to find sdk/pkg/ in $scriptPath');
  }
}

class _ElementNamer {
  final ConstructorElement currentFactoryConstructor;

  _ElementNamer(this.currentFactoryConstructor);

  void appendElementName(StringBuffer buffer, Element element) {
    // Synthetic FunctionElement(s) don't have a name or enclosing library.
    if (element.isSynthetic && element is FunctionElement) {
      return;
    }

    LibraryElement library = element.library;
    if (library == null) {
      throw new StateError('Unexpected element without library: $element');
    }
    String libraryName = library.name;

    String name = element.name ?? '';
    if (name.endsWith('=') &&
        element is PropertyAccessorElement &&
        element.isSetter) {
      name = name.substring(0, name.length - 1);
    }
    if (libraryName != 'dart.core' &&
        libraryName != 'dart.async' &&
        libraryName != 'test') {
      buffer.write('$libraryName::');
    }
    var enclosing = element.enclosingElement;
    if (enclosing is ClassElement) {
      buffer.write('${enclosing.name}::');
      if (currentFactoryConstructor != null &&
          identical(enclosing, currentFactoryConstructor.enclosingElement) &&
          element is TypeParameterElement) {
        String factoryConstructorName = currentFactoryConstructor.name;
        if (factoryConstructorName == '') {
          factoryConstructorName = '•';
        }
        buffer.write('$factoryConstructorName::');
      }
    }
    buffer.write('$name');
  }
}

class _FrontEndInferenceTest extends BaseAnalysisDriverTest {
  Future<String> runTest(String path, String code) async {
    Uri uri = provider.pathContext.toUri(path);

    List<int> lineStarts = new LineInfo.fromContent(code).lineStarts;
    fasta.CompilerContext.current.uriToSource[relativizeUri(uri).toString()] =
        new fasta.Source(lineStarts, UTF8.encode(code));

    var validation = new fasta.ValidatingInstrumentation();
    await validation.loadExpectations(uri);

    provider.newFile(path, code);

    AnalysisResult result = await driver.getResult(path);
    result.unit.accept(new _InstrumentationVisitor(validation, uri));

    validation.finish();

    if (validation.hasProblems) {
      if (fixProblems) {
        validation.fixSource(uri, true);
        return null;
      } else {
        return validation.problemsAsString;
      }
    } else {
      return null;
    }
  }
}

/// Instance of [InstrumentationValue] describing an [ExecutableElement].
class _InstrumentationValueForExecutableElement
    extends fasta.InstrumentationValue {
  final ExecutableElement element;
  final _ElementNamer elementNamer;

  _InstrumentationValueForExecutableElement(this.element, this.elementNamer);

  @override
  String toString() {
    StringBuffer buffer = new StringBuffer();
    elementNamer.appendElementName(buffer, element);
    return buffer.toString();
  }
}

/**
 * Instance of [InstrumentationValue] describing a [DartType].
 */
class _InstrumentationValueForType extends fasta.InstrumentationValue {
  final DartType type;
  final _ElementNamer elementNamer;

  _InstrumentationValueForType(this.type, this.elementNamer);

  @override
  String toString() {
    StringBuffer buffer = new StringBuffer();
    _appendType(buffer, type);
    return buffer.toString();
  }

  void _appendList<T>(StringBuffer buffer, String open, String close,
      List<T> items, String separator, writeItem(T item),
      {bool includeEmpty: false}) {
    if (!includeEmpty && items.isEmpty) {
      return;
    }
    buffer.write(open);
    bool first = true;
    for (T item in items) {
      if (!first) {
        buffer.write(separator);
      }
      writeItem(item);
      first = false;
    }
    buffer.write(close);
  }

  void _appendParameters(
      StringBuffer buffer, List<ParameterElement> parameters) {
    _appendList<ParameterElement>(buffer, '(', ')', parameters, ', ',
        (parameter) {
      _appendType(buffer, parameter.type);
    }, includeEmpty: true);
  }

  void _appendType(StringBuffer buffer, DartType type) {
    if (type is FunctionType) {
      _appendTypeArguments(buffer, type.typeArguments);
      _appendParameters(buffer, type.parameters);
      buffer.write(' -> ');
      _appendType(buffer, type.returnType);
    } else if (type is InterfaceType) {
      ClassElement element = type.element;
      elementNamer.appendElementName(buffer, element);
      _appendTypeArguments(buffer, type.typeArguments);
    } else if (type.isBottom) {
      buffer.write('<BottomType>');
    } else if (type is TypeParameterType) {
      elementNamer.appendElementName(buffer, type.element);
    } else {
      buffer.write(type.toString());
    }
  }

  void _appendTypeArguments(StringBuffer buffer, List<DartType> typeArguments) {
    _appendList<DartType>(buffer, '<', '>', typeArguments, ', ',
        (type) => _appendType(buffer, type));
  }
}

/**
 * Instance of [InstrumentationValue] describing a list of [DartType]s.
 */
class _InstrumentationValueForTypeArgs extends fasta.InstrumentationValue {
  final List<DartType> types;
  final _ElementNamer elementNamer;

  const _InstrumentationValueForTypeArgs(this.types, this.elementNamer);

  @override
  String toString() => types
      .map((type) =>
          new _InstrumentationValueForType(type, elementNamer).toString())
      .join(', ');
}

/**
 * Visitor for ASTs that reports instrumentation for types.
 */
class _InstrumentationVisitor extends RecursiveAstVisitor<Null> {
  final fasta.Instrumentation _instrumentation;
  final Uri uri;
  _ElementNamer elementNamer = new _ElementNamer(null);

  _InstrumentationVisitor(this._instrumentation, this.uri);

  visitBinaryExpression(BinaryExpression node) {
    super.visitBinaryExpression(node);
    _recordTarget(node.operator.charOffset, node.staticElement);
  }

  @override
  visitConstructorDeclaration(ConstructorDeclaration node) {
    _ElementNamer oldElementNamer = elementNamer;
    if (node.factoryKeyword != null) {
      // Factory constructors are represented in kernel as static methods, so
      // their type parameters get replicated, e.g.:
      //     class C<T> {
      //       factory C.ctor() {
      //         T t; // Refers to C::T
      //         ...
      //       }
      //     }
      // gets converted to:
      //     class C<T> {
      //       static C<T> C.ctor<T>() {
      //         T t; // Refers to C::ctor::T
      //         ...
      //       }
      //     }
      // So to match kernel behavior, we have to arrange for this renaming to
      // happen during output.
      elementNamer = new _ElementNamer(node.element);
    }
    super.visitConstructorDeclaration(node);
    elementNamer = oldElementNamer;
  }

  @override
  visitDeclaredIdentifier(DeclaredIdentifier node) {
    super.visitDeclaredIdentifier(node);
    if (node.type == null) {
      _recordType(node.identifier.offset, node.element.type);
    }
  }

  visitFunctionExpression(FunctionExpression node) {
    super.visitFunctionExpression(node);
    if (node.parent is! FunctionDeclaration) {
      DartType type = node.staticType;
      if (type is FunctionType) {
        _instrumentation.record(uri, node.offset, 'returnType',
            new _InstrumentationValueForType(type.returnType, elementNamer));
        List<FormalParameter> parameters = node.parameters.parameters;
        for (int i = 0; i < parameters.length; i++) {
          FormalParameter parameter = parameters[i];
          if (parameter is SimpleFormalParameter && parameter.type == null) {
            _recordType(parameter.offset, type.parameters[i].type);
          }
        }
      }
    }
  }

  @override
  visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    super.visitFunctionExpressionInvocation(node);
    if (node.typeArguments == null) {
      var inferredTypeArguments = _getInferredFunctionTypeArguments(
              node.function.staticType,
              node.staticInvokeType,
              node.typeArguments)
          .toList();
      if (inferredTypeArguments.isNotEmpty) {
        _recordTypeArguments(node.argumentList.offset, inferredTypeArguments);
      }
    }
  }

  visitIndexExpression(IndexExpression node) {
    super.visitIndexExpression(node);
    _recordTarget(node.leftBracket.charOffset, node.staticElement);
  }

  visitInstanceCreationExpression(InstanceCreationExpression node) {
    super.visitInstanceCreationExpression(node);
    DartType type = node.staticType;
    if (type is InterfaceType) {
      if (type.typeParameters.isNotEmpty &&
          node.constructorName.type.typeArguments == null) {
        _recordTypeArguments(node.constructorName.offset, type.typeArguments);
      }
    }
  }

  visitListLiteral(ListLiteral node) {
    super.visitListLiteral(node);
    if (node.typeArguments == null) {
      DartType type = node.staticType;
      if (type is InterfaceType) {
        _recordTypeArguments(node.offset, type.typeArguments);
      }
    }
  }

  visitMapLiteral(MapLiteral node) {
    super.visitMapLiteral(node);
    if (node.typeArguments == null) {
      DartType type = node.staticType;
      if (type is InterfaceType) {
        _recordTypeArguments(node.offset, type.typeArguments);
      }
    }
  }

  visitMethodInvocation(MethodInvocation node) {
    super.visitMethodInvocation(node);
    if (node.target != null) {
      _recordTarget(node.methodName.offset, node.methodName.staticElement);
    }
    if (node.typeArguments == null) {
      var inferredTypeArguments = _getInferredFunctionTypeArguments(
              node.function.staticType,
              node.staticInvokeType,
              node.typeArguments)
          .toList();
      if (inferredTypeArguments.isNotEmpty) {
        _recordTypeArguments(node.methodName.offset, inferredTypeArguments);
      }
    }
  }

  @override
  visitPrefixedIdentifier(PrefixedIdentifier node) {
    super.visitPrefixedIdentifier(node);
    if (node.prefix.staticElement is! PrefixElement &&
        node.prefix.staticElement is! ClassElement) {
      if (node.identifier.inGetterContext() ||
          node.identifier.inSetterContext()) {
        _recordTarget(node.identifier.offset, node.identifier.staticElement);
      }
    }
  }

  visitPrefixExpression(PrefixExpression node) {
    super.visitPrefixExpression(node);
    _recordTarget(node.operator.charOffset, node.staticElement);
  }

  @override
  visitPropertyAccess(PropertyAccess node) {
    super.visitPropertyAccess(node);
    if (node.propertyName.inGetterContext() ||
        node.propertyName.inSetterContext()) {
      _recordTarget(node.propertyName.offset, node.propertyName.staticElement);
    }
  }

  visitSimpleIdentifier(SimpleIdentifier node) {
    super.visitSimpleIdentifier(node);
    Element element = node.staticElement;
    void recordPromotions(DartType elementType) {
      if (node.inGetterContext() && !node.inDeclarationContext()) {
        int offset = node.offset;
        DartType type = node.staticType;
        if (!identical(type, elementType)) {
          _instrumentation.record(uri, offset, 'promotedType',
              new _InstrumentationValueForType(type, elementNamer));
        }
      }
    }

    if (element is LocalVariableElement) {
      recordPromotions(element.type);
    } else if (element is ParameterElement) {
      recordPromotions(element.type);
    }
  }

  visitVariableDeclarationList(VariableDeclarationList node) {
    super.visitVariableDeclarationList(node);
    if (node.type == null) {
      for (VariableDeclaration variable in node.variables) {
        VariableElement element = variable.element;
        if (element is LocalVariableElement) {
          _recordType(variable.name.offset, element.type);
        } else {
          _recordTopType(variable.name.offset, element.type);
        }
      }
    }
  }

  /// Based on DDC code generator's `_emitFunctionTypeArguments`
  Iterable<DartType> _getInferredFunctionTypeArguments(
      DartType g, DartType f, TypeArgumentList typeArgs) {
    if (g is FunctionType &&
        g.typeFormals.isNotEmpty &&
        f is FunctionType &&
        f.typeFormals.isEmpty) {
      return _recoverTypeArguments(g, f);
    } else {
      return const [];
    }
  }

  void _recordTarget(int offset, Element element) {
    if (element is ExecutableElement) {
      _instrumentation.record(uri, offset, 'target',
          new _InstrumentationValueForExecutableElement(element, elementNamer));
    }
  }

  void _recordTopType(int offset, DartType type) {
    _instrumentation.record(uri, offset, 'topType',
        new _InstrumentationValueForType(type, elementNamer));
  }

  void _recordType(int offset, DartType type) {
    _instrumentation.record(uri, offset, 'type',
        new _InstrumentationValueForType(type, elementNamer));
  }

  void _recordTypeArguments(int offset, List<DartType> typeArguments) {
    _instrumentation.record(uri, offset, 'typeArgs',
        new _InstrumentationValueForTypeArgs(typeArguments, elementNamer));
  }

  /// Based on DDC code generator's `_recoverTypeArguments`
  Iterable<DartType> _recoverTypeArguments(FunctionType g, FunctionType f) {
    assert(identical(g.element, f.element));
    assert(g.typeFormals.isNotEmpty && f.typeFormals.isEmpty);
    assert(g.typeFormals.length + g.typeArguments.length ==
        f.typeArguments.length);
    return f.typeArguments.skip(g.typeArguments.length);
  }
}
