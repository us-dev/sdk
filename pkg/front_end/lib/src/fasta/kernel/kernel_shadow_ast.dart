// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This file declares a "shadow hierarchy" of concrete classes which extend
/// the kernel class hierarchy, adding methods and fields needed by the
/// BodyBuilder.
///
/// Instances of these classes may be created using the factory methods in
/// `ast_factory.dart`.
///
/// Note that these classes represent the Dart language prior to desugaring.
/// When a single Dart construct desugars to a tree containing multiple kernel
/// AST nodes, the shadow class extends the kernel object at the top of the
/// desugared tree.
///
/// This means that in some cases multiple shadow classes may extend the same
/// kernel class, because multiple constructs in Dart may desugar to a tree
/// with the same kind of root node.
import 'package:front_end/src/base/instrumentation.dart';
import 'package:front_end/src/fasta/type_inference/dependency_collector.dart';
import 'package:front_end/src/fasta/type_inference/type_inference_engine.dart';
import 'package:front_end/src/fasta/type_inference/type_inference_listener.dart';
import 'package:front_end/src/fasta/type_inference/type_inferrer.dart';
import 'package:front_end/src/fasta/type_inference/type_promotion.dart';
import 'package:front_end/src/fasta/type_inference/type_schema.dart';
import 'package:front_end/src/fasta/type_inference/type_schema_elimination.dart';
import 'package:kernel/ast.dart'
    hide InvalidExpression, InvalidInitializer, InvalidStatement;
import 'package:kernel/frontend/accessors.dart';
import 'package:kernel/type_algebra.dart';

import '../errors.dart' show internalError;

/// Computes the return type of a (possibly factory) constructor.
InterfaceType computeConstructorReturnType(Member constructor) {
  if (constructor is Constructor) {
    return constructor.enclosingClass.thisType;
  } else {
    return constructor.function.returnType;
  }
}

List<DartType> getExplicitTypeArguments(Arguments arguments) {
  if (arguments is KernelArguments) {
    return arguments._hasExplicitTypeArguments ? arguments.types : null;
  } else {
    // This code path should only be taken in situations where there are no
    // type arguments at all, e.g. calling a user-definable operator.
    assert(arguments.types.isEmpty);
    return null;
  }
}

/// Concrete shadow object representing a set of invocation arguments.
class KernelArguments extends Arguments {
  bool _hasExplicitTypeArguments;

  KernelArguments(List<Expression> positional,
      {List<DartType> types, List<NamedExpression> named})
      : _hasExplicitTypeArguments = types != null && types.isNotEmpty,
        super(positional, types: types, named: named);

  static void setExplicitArgumentTypes(
      KernelArguments arguments, List<DartType> types) {
    arguments.types.clear();
    arguments.types.addAll(types);
    arguments._hasExplicitTypeArguments = true;
  }
}

/// Shadow object for [AsExpression].
class KernelAsExpression extends AsExpression implements KernelExpression {
  KernelAsExpression(Expression operand, DartType type) : super(operand, type);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.asExpressionEnter(this, typeContext) || typeNeeded;
    inferrer.inferExpression(operand, null, false);
    var inferredType = typeNeeded ? type : null;
    inferrer.listener.asExpressionExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [AwaitExpression].
class KernelAwaitExpression extends AwaitExpression
    implements KernelExpression {
  KernelAwaitExpression(Expression operand) : super(operand);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Inference dependencies are the dependencies of the awaited expression.
    collector.collectDependencies(operand);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.awaitExpressionEnter(this, typeContext) || typeNeeded;
    if (!inferrer.typeSchemaEnvironment.isEmptyContext(typeContext)) {
      typeContext = inferrer.wrapFutureOrType(typeContext);
    }
    var inferredType =
        inferrer.inferExpression(operand, typeContext, typeNeeded);
    inferredType = inferrer.typeSchemaEnvironment.flattenFutures(inferredType);
    inferrer.listener.awaitExpressionExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a statement block in kernel form.
class KernelBlock extends Block implements KernelStatement {
  KernelBlock(List<Statement> statements) : super(statements);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.blockEnter(this);
    for (var statement in statements) {
      inferrer.inferStatement(statement);
    }
    inferrer.listener.blockExit(this);
  }
}

/// Concrete shadow object representing a boolean literal in kernel form.
class KernelBoolLiteral extends BoolLiteral implements KernelExpression {
  KernelBoolLiteral(bool value) : super(value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.boolLiteralEnter(this, typeContext) || typeNeeded;
    var inferredType = typeNeeded ? inferrer.coreTypes.boolClass.rawType : null;
    inferrer.listener.boolLiteralExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a cascade expression.
///
/// A cascade expression of the form `a..b()..c()` is represented as the kernel
/// expression:
///
///     let v = a in
///         let _ = v.b() in
///             let _ = v.c() in
///                 v
///
/// In the documentation that follows, `v` is referred to as the "cascade
/// variable"--this is the variable that remembers the value of the expression
/// preceding the first `..` while the cascades are being evaluated.
///
/// After constructing a [KernelCascadeExpression], the caller should
/// call [finalize] with an expression representing the expression after the
/// `..`.  If a further `..` follows that expression, the caller should call
/// [extend] followed by [finalize] for each subsequent cascade.
class KernelCascadeExpression extends Let implements KernelExpression {
  /// Pointer to the last "let" expression in the cascade.
  Let nextCascade;

  /// Creates a [KernelCascadeExpression] using [variable] as the cascade
  /// variable.  Caller is responsible for ensuring that [variable]'s
  /// initializer is the expression preceding the first `..` of the cascade
  /// expression.
  KernelCascadeExpression(KernelVariableDeclaration variable)
      : super(
            variable,
            makeLet(new VariableDeclaration.forValue(new _UnfinishedCascade()),
                new VariableGet(variable))) {
    nextCascade = body;
  }

  /// Adds a new unfinalized section to the end of the cascade.  Should be
  /// called after the previous cascade section has been finalized.
  void extend() {
    assert(nextCascade.variable.initializer is! _UnfinishedCascade);
    Let newCascade = makeLet(
        new VariableDeclaration.forValue(new _UnfinishedCascade()),
        nextCascade.body);
    nextCascade.body = newCascade;
    newCascade.parent = nextCascade;
    nextCascade = newCascade;
  }

  /// Finalizes the last cascade section with the given [expression].
  void finalize(Expression expression) {
    assert(nextCascade.variable.initializer is _UnfinishedCascade);
    nextCascade.variable.initializer = expression;
    expression.parent = nextCascade.variable;
  }

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // The inference dependencies are the inference dependencies of the cascade
    // target.
    collector.collectDependencies(variable.initializer);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded = inferrer.listener.cascadeExpressionEnter(this, typeContext) ||
        typeNeeded;
    var lhsType = inferrer.inferExpression(
        variable.initializer, typeContext, typeNeeded || inferrer.strongMode);
    if (inferrer.strongMode) {
      variable.type = lhsType;
    }
    Let section = body;
    while (true) {
      inferrer.inferExpression(section.variable.initializer, null, false);
      if (section.body is! Let) break;
      section = section.body;
    }
    inferrer.listener.cascadeExpressionExit(this, lhsType);
    return lhsType;
  }
}

/// Concrete shadow object representing a conditional expression in kernel form.
/// Shadow object for [ConditionalExpression].
class KernelConditionalExpression extends ConditionalExpression
    implements KernelExpression {
  KernelConditionalExpression(
      Expression condition, Expression then, Expression otherwise)
      : super(condition, then, otherwise, const DynamicType());

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Inference dependencies are the union of the inference dependencies of the
    // two returned sub-expressions.
    collector.collectDependencies(then);
    collector.collectDependencies(otherwise);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.conditionalExpressionEnter(this, typeContext) ||
            typeNeeded;
    if (!inferrer.isTopLevel) {
      inferrer.inferExpression(
          condition, inferrer.coreTypes.boolClass.rawType, false);
    }
    DartType thenType = inferrer.inferExpression(then, typeContext, true);
    DartType otherwiseType =
        inferrer.inferExpression(otherwise, typeContext, true);
    DartType type = inferrer.typeSchemaEnvironment
        .getLeastUpperBound(thenType, otherwiseType);
    staticType = type;
    var inferredType = typeNeeded ? type : null;
    inferrer.listener.conditionalExpressionExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [ConstructorInvocation].
class KernelConstructorInvocation extends ConstructorInvocation
    implements KernelExpression {
  final Member _initialTarget;

  KernelConstructorInvocation(
      Constructor target, this._initialTarget, Arguments arguments,
      {bool isConst: false})
      : super(target, arguments, isConst: isConst);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.constructorInvocationEnter(this, typeContext) ||
            typeNeeded;
    var inferredType = inferrer.inferInvocation(
        typeContext,
        typeNeeded,
        fileOffset,
        _initialTarget.function.functionType,
        computeConstructorReturnType(_initialTarget),
        arguments);
    inferrer.listener.constructorInvocationExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete implementation of [DependencyCollector] specialized to work with
/// kernel objects.
class KernelDependencyCollector extends DependencyCollectorImpl {
  @override
  void collectDependencies(Expression expression) {
    if (expression is KernelExpression) {
      // Use polymorphic dispatch on [KernelExpression] to perform whatever kind
      // of type inference is correct for this kind of statement.
      // TODO(paulberry): experiment to see if dynamic dispatch would be better,
      // so that the type hierarchy will be simpler (which may speed up "is"
      // checks).
      expression._collectDependencies(this);
    } else {
      // Encountered an expression type for which type inference is not yet
      // implemented, so just assume the expression does not have an immediately
      // evident type for now.
      // TODO(paulberry): once the BodyBuilder uses shadow classes for
      // everything, this case should no longer be needed.
      recordNotImmediatelyEvident(expression.fileOffset);
    }
  }
}

/// Shadow object for [DirectMethodInvocation].
class KernelDirectMethodInvocation extends DirectMethodInvocation
    implements KernelExpression {
  KernelDirectMethodInvocation(
      Expression receiver, Procedure target, Arguments arguments)
      : super(receiver, target, arguments);

  KernelDirectMethodInvocation.byReference(
      Expression receiver, Reference targetReference, Arguments arguments)
      : super.byReference(receiver, targetReference, arguments);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // TODO(paulberry): Determine the right thing to do here.
    throw 'TODO(paulberry)';
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [DirectPropertyGet].
class KernelDirectPropertyGet extends DirectPropertyGet
    implements KernelExpression {
  KernelDirectPropertyGet(Expression receiver, Member target)
      : super(receiver, target);

  KernelDirectPropertyGet.byReference(
      Expression receiver, Reference targetReference)
      : super.byReference(receiver, targetReference);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // TODO(paulberry): Determine the right thing to do here.
    throw 'TODO(paulberry)';
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [DirectPropertySet].
class KernelDirectPropertySet extends DirectPropertySet
    implements KernelExpression {
  KernelDirectPropertySet(Expression receiver, Member target, Expression value)
      : super(receiver, target, value);

  KernelDirectPropertySet.byReference(
      Expression receiver, Reference targetReference, Expression value)
      : super.byReference(receiver, targetReference, value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Assignment expressions are not immediately evident expressions.
    collector.recordNotImmediatelyEvident(fileOffset);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Concrete shadow object representing a double literal in kernel form.
class KernelDoubleLiteral extends DoubleLiteral implements KernelExpression {
  KernelDoubleLiteral(double value) : super(value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.doubleLiteralEnter(this, typeContext) || typeNeeded;
    var inferredType =
        typeNeeded ? inferrer.coreTypes.doubleClass.rawType : null;
    inferrer.listener.doubleLiteralExit(this, inferredType);
    return inferredType;
  }
}

/// Common base class for shadow objects representing expressions in kernel
/// form.
abstract class KernelExpression implements Expression {
  /// Collects any dependencies of [expression], and reports errors if the
  /// expression does not have an immediately evident type.
  void _collectDependencies(KernelDependencyCollector collector);

  /// Calls back to [inferrer] to perform type inference for whatever concrete
  /// type of [KernelExpression] this is.
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded);
}

/// Concrete shadow object representing an expression statement in kernel form.
class KernelExpressionStatement extends ExpressionStatement
    implements KernelStatement {
  KernelExpressionStatement(Expression expression) : super(expression);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.expressionStatementEnter(this);
    inferrer.inferExpression(expression, null, false);
    inferrer.listener.expressionStatementExit(this);
  }
}

/// Shadow object for [StaticInvocation] when the procedure being invoked is a
/// factory constructor.
class KernelFactoryConstructorInvocation extends StaticInvocation
    implements KernelExpression {
  final Member _initialTarget;

  KernelFactoryConstructorInvocation(
      Procedure target, this._initialTarget, Arguments arguments,
      {bool isConst: false})
      : super(target, arguments, isConst: isConst);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.constructorInvocationEnter(this, typeContext) ||
            typeNeeded;
    var inferredType = inferrer.inferInvocation(
        typeContext,
        typeNeeded,
        fileOffset,
        _initialTarget.function.functionType,
        computeConstructorReturnType(_initialTarget),
        arguments);
    inferrer.listener.constructorInvocationExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a field in kernel form.
class KernelField extends Field {
  bool _implicitlyTyped = true;

  FieldNode _fieldNode;

  bool _isInferred = false;

  KernelTypeInferrer _typeInferrer;

  KernelField(Name name, {String fileUri}) : super(name, fileUri: fileUri) {}

  @override
  void set type(DartType value) {
    _implicitlyTyped = false;
    super.type = value;
  }

  String get _fileUri {
    // TODO(paulberry): This is a hack.  We should use this.fileUri, because we
    // want the URI of the compilation unit.  But that gives a relative URI,
    // and I don't know what it's relative to or how to convert it to an
    // absolute URI.
    return enclosingLibrary.importUri.toString();
  }

  void _setInferredType(DartType inferredType) {
    _isInferred = true;
    super.type = inferredType;
  }
}

/// Concrete shadow object representing a for-in loop in kernel form.
class KernelForInStatement extends ForInStatement implements KernelStatement {
  final bool _declaresVariable;

  KernelForInStatement(VariableDeclaration variable, Expression iterable,
      Statement body, this._declaresVariable,
      {bool isAsync: false})
      : super(variable, iterable, body, isAsync: isAsync);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.forInStatementEnter(this);
    var iterableClass = isAsync
        ? inferrer.coreTypes.streamClass
        : inferrer.coreTypes.iterableClass;
    DartType context;
    bool typeNeeded = false;
    KernelVariableDeclaration variable;
    if (_declaresVariable) {
      variable = this.variable;
      if (variable._implicitlyTyped) {
        typeNeeded = true;
        // TODO(paulberry): In this case, should the context be `Iterable<?>`?
      } else {
        context = inferrer.wrapType(variable.type, iterableClass);
      }
    } else {
      // TODO(paulberry): In this case, should the context be based on the
      // declared type of the loop variable?
      // TODO(paulberry): Note that when [_declaresVariable] is `false`, the
      // body starts with an assignment from the synthetic loop variable to
      // another variable.  We need to make sure any type inference diagnostics
      // that occur related to this assignment are reported at the correct
      // locations.
    }
    var inferredExpressionType =
        inferrer.inferExpression(iterable, context, typeNeeded);
    if (typeNeeded) {
      var inferredType = const DynamicType();
      if (inferredExpressionType is InterfaceType) {
        InterfaceType supertype = inferrer.classHierarchy
            .getTypeAsInstanceOf(inferredExpressionType, iterableClass);
        if (supertype != null) {
          inferredType = supertype.typeArguments[0];
        }
      }
      inferrer.instrumentation?.record(
          Uri.parse(inferrer.uri),
          variable.fileOffset,
          'type',
          new InstrumentationValueForType(inferredType));
      variable.type = inferredType;
    }
    inferrer.inferStatement(body);
    inferrer.listener.forInStatementExit(this);
  }
}

/// Concrete shadow object representing a local function declaration in kernel
/// form.
class KernelFunctionDeclaration extends FunctionDeclaration
    implements KernelStatement {
  KernelFunctionDeclaration(VariableDeclaration variable, FunctionNode function)
      : super(variable, function);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.functionDeclarationEnter(this);
    var oldClosureContext = inferrer.closureContext;
    inferrer.closureContext =
        new ClosureContext(inferrer, function.asyncMarker, function.returnType);
    inferrer.inferStatement(function.body);
    inferrer.closureContext = oldClosureContext;
    inferrer.listener.functionDeclarationExit(this);
  }
}

/// Concrete shadow object representing a function expression in kernel form.
class KernelFunctionExpression extends FunctionExpression
    implements KernelExpression {
  KernelFunctionExpression(FunctionNode function) : super(function);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    for (KernelVariableDeclaration parameter in function.positionalParameters) {
      if (parameter._implicitlyTyped) {
        collector.recordNotImmediatelyEvident(parameter.fileOffset);
      }
    }
    for (KernelVariableDeclaration parameter in function.namedParameters) {
      if (parameter._implicitlyTyped) {
        collector.recordNotImmediatelyEvident(parameter.fileOffset);
      }
    }
    var body = function.body;
    if (body is ReturnStatement) {
      // The inference dependencies are the inference dependencies of the return
      // expression.
      collector.collectDependencies(body.expression);
    } else {
      collector.recordNotImmediatelyEvident(fileOffset);
    }
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded = inferrer.listener.functionExpressionEnter(this, typeContext) ||
        typeNeeded;
    // TODO(paulberry): do we also need to visit default parameter values?

    // Let `<T0, ..., Tn>` be the set of type parameters of the closure (with
    // `n`=0 if there are no type parameters).
    List<TypeParameter> typeParameters = function.typeParameters;

    // Let `(P0 x0, ..., Pm xm)` be the set of formal parameters of the closure
    // (including required, positional optional, and named optional parameters).
    // If any type `Pi` is missing, denote it as `_`.
    List<VariableDeclaration> formals = function.positionalParameters.toList()
      ..addAll(function.namedParameters);

    // Let `B` denote the closure body.  If `B` is an expression function body
    // (`=> e`), treat it as equivalent to a block function body containing a
    // single `return` statement (`{ return e; }`).

    // Attempt to match `K` as a function type compatible with the closure (that
    // is, one having n type parameters and a compatible set of formal
    // parameters).  If there is a successful match, let `<S0, ..., Sn>` be the
    // set of matched type parameters and `(Q0, ..., Qm)` be the set of matched
    // formal parameter types, and let `N` be the return type.
    Substitution substitution;
    List<DartType> formalTypesFromContext =
        new List<DartType>.filled(formals.length, null);
    DartType returnContext;
    if (inferrer.strongMode && typeContext is FunctionType) {
      for (int i = 0; i < formals.length; i++) {
        if (i < function.positionalParameters.length) {
          formalTypesFromContext[i] =
              inferrer.getPositionalParameterType(typeContext, i);
        } else {
          formalTypesFromContext[i] =
              inferrer.getNamedParameterType(typeContext, formals[i].name);
        }
      }
      returnContext = typeContext.returnType;

      // Let `[T/S]` denote the type substitution where each `Si` is replaced with
      // the corresponding `Ti`.
      var substitutionMap = <TypeParameter, DartType>{};
      for (int i = 0; i < typeContext.typeParameters.length; i++) {
        substitutionMap[typeContext.typeParameters[i]] =
            i < typeParameters.length
                ? new TypeParameterType(typeParameters[i])
                : const DynamicType();
      }
      substitution = Substitution.fromMap(substitutionMap);
    } else {
      // If the match is not successful because  `K` is `_`, let all `Si`, all
      // `Qi`, and `N` all be `_`.

      // If the match is not successful for any other reason, this will result in
      // a type error, so the implementation is free to choose the best error
      // recovery path.
      substitution = Substitution.empty;
    }

    // Define `Ri` as follows: if `Pi` is not `_`, let `Ri` be `Pi`.
    // Otherwise, if `Qi` is not `_`, let `Ri` be the greatest closure of
    // `Qi[T/S]` with respect to `?`.  Otherwise, let `Ri` be `dynamic`.
    for (int i = 0; i < formals.length; i++) {
      KernelVariableDeclaration formal = formals[i];
      if (KernelVariableDeclaration.isImplicitlyTyped(formal)) {
        DartType inferredType;
        if (formalTypesFromContext[i] != null) {
          inferredType = greatestClosure(inferrer.coreTypes,
              substitution.substituteType(formalTypesFromContext[i]));
        } else {
          inferredType = const DynamicType();
        }
        inferrer.instrumentation?.record(
            Uri.parse(inferrer.uri),
            formal.fileOffset,
            'type',
            new InstrumentationValueForType(inferredType));
        formal.type = inferredType;
      }
    }

    // Let `N'` be `N[T/S]`.  The [ClosureContext] constructor will adjust
    // accordingly if the closure is declared with `async`, `async*`, or
    // `sync*`.
    if (returnContext != null) {
      returnContext = substitution.substituteType(returnContext);
    }

    // Apply type inference to `B` in return context `N’`, with any references
    // to `xi` in `B` having type `Pi`.  This produces `B’`.
    bool isExpressionFunction = function.body is ReturnStatement;
    bool needToSetReturnType = isExpressionFunction || inferrer.strongMode;
    ClosureContext oldClosureContext = inferrer.closureContext;
    ClosureContext closureContext =
        new ClosureContext(inferrer, function.asyncMarker, returnContext);
    inferrer.closureContext = closureContext;
    inferrer.inferStatement(function.body);

    // If the closure is declared with `async*` or `sync*`, let `M` be the least
    // upper bound of the types of the `yield` expressions in `B’`, or `void` if
    // `B’` contains no `yield` expressions.  Otherwise, let `M` be the least
    // upper bound of the types of the `return` expressions in `B’`, or `void`
    // if `B’` contains no `return` expressions.
    DartType inferredReturnType;
    if (needToSetReturnType || typeNeeded) {
      inferredReturnType =
          closureContext.inferReturnType(inferrer, isExpressionFunction);
    }

    // Then the result of inference is `<T0, ..., Tn>(R0 x0, ..., Rn xn) B` with
    // type `<T0, ..., Tn>(R0, ..., Rn) -> M’` (with some of the `Ri` and `xi`
    // denoted as optional or named parameters, if appropriate).
    if (needToSetReturnType) {
      inferrer.instrumentation?.record(Uri.parse(inferrer.uri), fileOffset,
          'returnType', new InstrumentationValueForType(inferredReturnType));
      function.returnType = inferredReturnType;
    }
    inferrer.closureContext = oldClosureContext;
    var inferredType = typeNeeded ? function.functionType : null;
    inferrer.listener.functionExpressionExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing an if statement in kernel form.
class KernelIfStatement extends IfStatement implements KernelStatement {
  KernelIfStatement(Expression condition, Statement then, Statement otherwise)
      : super(condition, then, otherwise);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.ifStatementEnter(this);
    inferrer.inferExpression(
        condition, inferrer.coreTypes.boolClass.rawType, false);
    inferrer.inferStatement(then);
    if (otherwise != null) inferrer.inferStatement(otherwise);
    inferrer.listener.ifStatementExit(this);
  }
}

/// Common base class for shadow objects representing initializers in kernel
/// form.
abstract class KernelInitializer implements Initializer {
  /// Performs type inference for whatever concrete type of [KernelInitializer]
  /// this is.
  void _inferInitializer(KernelTypeInferrer inferrer);
}

/// Concrete shadow object representing an integer literal in kernel form.
class KernelIntLiteral extends IntLiteral implements KernelExpression {
  KernelIntLiteral(int value) : super(value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.intLiteralEnter(this, typeContext) || typeNeeded;
    var inferredType = typeNeeded ? inferrer.coreTypes.intClass.rawType : null;
    inferrer.listener.intLiteralExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a non-inverted "is" test in kernel form.
class KernelIsExpression extends IsExpression implements KernelExpression {
  KernelIsExpression(Expression operand, DartType type) : super(operand, type);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.isExpressionEnter(this, typeContext) || typeNeeded;
    inferrer.inferExpression(operand, null, false);
    var inferredType = typeNeeded ? inferrer.coreTypes.boolClass.rawType : null;
    inferrer.listener.isExpressionExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing an inverted "is" test in kernel form.
class KernelIsNotExpression extends Not implements KernelExpression {
  KernelIsNotExpression(Expression operand, DartType type, int charOffset)
      : super(new IsExpression(operand, type)..fileOffset = charOffset);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    IsExpression isExpression = this.operand;
    typeNeeded =
        inferrer.listener.isNotExpressionEnter(this, typeContext) || typeNeeded;
    inferrer.inferExpression(isExpression.operand, null, false);
    var inferredType = typeNeeded ? inferrer.coreTypes.boolClass.rawType : null;
    inferrer.listener.isNotExpressionExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a list literal in kernel form.
class KernelListLiteral extends ListLiteral implements KernelExpression {
  final DartType _declaredTypeArgument;

  KernelListLiteral(List<Expression> expressions,
      {DartType typeArgument, bool isConst: false})
      : _declaredTypeArgument = typeArgument,
        super(expressions,
            typeArgument: typeArgument ?? const DynamicType(),
            isConst: isConst);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    if (_declaredTypeArgument == null) {
      expressions.forEach(collector.collectDependencies);
    }
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.listLiteralEnter(this, typeContext) || typeNeeded;
    var listClass = inferrer.coreTypes.listClass;
    var listType = listClass.thisType;
    List<DartType> inferredTypes;
    DartType inferredTypeArgument;
    List<DartType> formalTypes;
    List<DartType> actualTypes;
    bool inferenceNeeded = _declaredTypeArgument == null && inferrer.strongMode;
    if (inferenceNeeded) {
      inferredTypes = [const UnknownType()];
      inferrer.typeSchemaEnvironment.inferGenericFunctionOrType(listType,
          listClass.typeParameters, null, null, typeContext, inferredTypes);
      inferredTypeArgument = inferredTypes[0];
      formalTypes = [];
      actualTypes = [];
    } else {
      inferredTypeArgument = _declaredTypeArgument ?? const DynamicType();
    }
    if (inferenceNeeded || !inferrer.isTopLevel) {
      for (var expression in expressions) {
        var expressionType = inferrer.inferExpression(
            expression, inferredTypeArgument, inferenceNeeded);
        if (inferenceNeeded) {
          formalTypes.add(listType.typeArguments[0]);
          actualTypes.add(expressionType);
        }
      }
    }
    if (inferenceNeeded) {
      inferrer.typeSchemaEnvironment.inferGenericFunctionOrType(
          listType,
          listClass.typeParameters,
          formalTypes,
          actualTypes,
          typeContext,
          inferredTypes);
      inferredTypeArgument = inferredTypes[0];
      inferrer.instrumentation?.record(
          Uri.parse(inferrer.uri),
          fileOffset,
          'typeArgs',
          new InstrumentationValueForTypeArgs([inferredTypeArgument]));
      typeArgument = inferredTypeArgument;
    }
    var inferredType = typeNeeded
        ? new InterfaceType(listClass, [inferredTypeArgument])
        : null;
    inferrer.listener.listLiteralExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [LogicalExpression].
class KernelLogicalExpression extends LogicalExpression
    implements KernelExpression {
  KernelLogicalExpression(Expression left, String operator, Expression right)
      : super(left, operator, right);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [MapLiteral].
class KernelMapLiteral extends MapLiteral implements KernelExpression {
  final DartType _declaredKeyType;
  final DartType _declaredValueType;

  KernelMapLiteral(List<MapEntry> entries,
      {DartType keyType, DartType valueType, bool isConst: false})
      : _declaredKeyType = keyType,
        _declaredValueType = valueType,
        super(entries,
            keyType: keyType ?? const DynamicType(),
            valueType: valueType ?? const DynamicType(),
            isConst: isConst);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    assert((_declaredKeyType == null) == (_declaredValueType == null));
    if (_declaredKeyType == null) {
      for (var entry in entries) {
        collector.collectDependencies(entry.key);
        collector.collectDependencies(entry.value);
      }
    }
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.mapLiteralEnter(this, typeContext) || typeNeeded;
    var mapClass = inferrer.coreTypes.mapClass;
    var mapType = mapClass.thisType;
    List<DartType> inferredTypes;
    DartType inferredKeyType;
    DartType inferredValueType;
    List<DartType> formalTypes;
    List<DartType> actualTypes;
    assert((_declaredKeyType == null) == (_declaredValueType == null));
    bool inferenceNeeded = _declaredKeyType == null && inferrer.strongMode;
    if (inferenceNeeded) {
      inferredTypes = [const UnknownType(), const UnknownType()];
      inferrer.typeSchemaEnvironment.inferGenericFunctionOrType(mapType,
          mapClass.typeParameters, null, null, typeContext, inferredTypes);
      inferredKeyType = inferredTypes[0];
      inferredValueType = inferredTypes[1];
      formalTypes = [];
      actualTypes = [];
    } else {
      inferredKeyType = _declaredKeyType ?? const DynamicType();
      inferredValueType = _declaredValueType ?? const DynamicType();
    }
    if (inferenceNeeded || !inferrer.isTopLevel) {
      for (var entry in entries) {
        var keyType = inferrer.inferExpression(
            entry.key, inferredKeyType, inferenceNeeded);
        var valueType = inferrer.inferExpression(
            entry.value, inferredValueType, inferenceNeeded);
        if (inferenceNeeded) {
          formalTypes.addAll(mapType.typeArguments);
          actualTypes.add(keyType);
          actualTypes.add(valueType);
        }
      }
    }
    if (inferenceNeeded) {
      inferrer.typeSchemaEnvironment.inferGenericFunctionOrType(
          mapType,
          mapClass.typeParameters,
          formalTypes,
          actualTypes,
          typeContext,
          inferredTypes);
      inferredKeyType = inferredTypes[0];
      inferredValueType = inferredTypes[1];
      inferrer.instrumentation?.record(
          Uri.parse(inferrer.uri),
          fileOffset,
          'typeArgs',
          new InstrumentationValueForTypeArgs(
              [inferredKeyType, inferredValueType]));
      keyType = inferredKeyType;
      valueType = inferredValueType;
    }
    var inferredType = typeNeeded
        ? new InterfaceType(mapClass, [inferredKeyType, inferredValueType])
        : null;
    inferrer.listener.mapLiteralExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [MethodInvocation].
class KernelMethodInvocation extends MethodInvocation
    implements KernelExpression {
  KernelMethodInvocation(Expression receiver, Name name, Arguments arguments,
      [Procedure interfaceTarget])
      : super(receiver, name, arguments, interfaceTarget);

  KernelMethodInvocation.byReference(Expression receiver, Name name,
      Arguments arguments, Reference interfaceTargetReference)
      : super.byReference(receiver, name, arguments, interfaceTargetReference);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // The inference dependencies are the inference dependencies of the
    // receiver.
    collector.collectDependencies(receiver);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded = inferrer.listener.methodInvocationEnter(this, typeContext) ||
        typeNeeded;
    // First infer the receiver so we can look up the method that was invoked.
    var receiverType = inferrer.inferExpression(receiver, null, true);
    bool isOverloadedArithmeticOperator = false;
    Member interfaceMember;
    if (receiverType is InterfaceType) {
      interfaceMember = inferrer.classHierarchy
          .getInterfaceMember(receiverType.classNode, name);
      if (interfaceMember is Procedure) {
        // Our non-strong golden files currently don't include interface
        // targets, so we can't store the interface target without causing tests
        // to fail.  TODO(paulberry): fix this.
        if (inferrer.strongMode) {
          inferrer.instrumentation?.record(Uri.parse(inferrer.uri), fileOffset,
              'target', new InstrumentationValueForMember(interfaceMember));
          interfaceTarget = interfaceMember;
        }
        isOverloadedArithmeticOperator = inferrer.typeSchemaEnvironment
            .isOverloadedArithmeticOperator(interfaceMember);
      }
    }
    var calleeType =
        inferrer.getCalleeFunctionType(interfaceMember, receiverType, name);
    var inferredType = inferrer.inferInvocation(typeContext, typeNeeded,
        fileOffset, calleeType, calleeType.returnType, arguments,
        isOverloadedArithmeticOperator: isOverloadedArithmeticOperator,
        receiverType: receiverType);
    inferrer.listener.methodInvocationExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [Not].
class KernelNot extends Not implements KernelExpression {
  KernelNot(Expression operand) : super(operand);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Concrete shadow object representing a null literal in kernel form.
class KernelNullLiteral extends NullLiteral implements KernelExpression {
  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.nullLiteralEnter(this, typeContext) || typeNeeded;
    var inferredType = typeNeeded ? inferrer.coreTypes.nullClass.rawType : null;
    inferrer.listener.nullLiteralExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [PropertyGet].
class KernelPropertyGet extends PropertyGet implements KernelExpression {
  KernelPropertyGet(Expression receiver, Name name, [Member interfaceTarget])
      : super(receiver, name, interfaceTarget);

  KernelPropertyGet.byReference(
      Expression receiver, Name name, Reference interfaceTargetReference)
      : super.byReference(receiver, name, interfaceTargetReference);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // A simple or qualified identifier referring to a top level function,
    // static variable, field, getter; or a static class variable, static getter
    // or method; or an instance method; has the inferred type of the referent.
    // - Otherwise, if the identifier has no inferred or annotated type then it
    //   is an error.
    // - Note: specifically, references to instance fields and instance getters
    //   are disallowed here.
    // - The inference dependency of the identifier is the referent if the
    //   referent is a candidate for inference.  Otherwise there are no
    //   inference dependencies.
    // TODO(paulberry): implement the proper logic here.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.propertyGetEnter(this, typeContext) || typeNeeded;
    // First infer the receiver so we can look up the getter that was invoked.
    var receiverType = inferrer.inferExpression(receiver, null, true);
    Member interfaceMember;
    if (receiverType is InterfaceType) {
      interfaceMember = inferrer.classHierarchy
          .getInterfaceMember(receiverType.classNode, name);
      if (inferrer.isTopLevel &&
          ((interfaceMember is Procedure &&
                  interfaceMember.kind == ProcedureKind.Getter) ||
              interfaceMember is Field)) {
        // References to fields and getters can't be relied upon for top level
        // inference.
        inferrer.recordNotImmediatelyEvident(fileOffset);
      }
      // Our non-strong golden files currently don't include interface targets,
      // so we can't store the interface target without causing tests to fail.
      // TODO(paulberry): fix this.
      if (inferrer.strongMode) {
        inferrer.instrumentation?.record(Uri.parse(inferrer.uri), fileOffset,
            'target', new InstrumentationValueForMember(interfaceMember));
        interfaceTarget = interfaceMember;
      }
    }
    var inferredType =
        inferrer.getCalleeType(interfaceMember, receiverType, name);
    // TODO(paulberry): Infer tear-off type arguments if appropriate.
    inferrer.listener.propertyGetExit(this, inferredType);
    return typeNeeded ? inferredType : null;
  }
}

/// Shadow object for [PropertyGet].
class KernelPropertySet extends PropertySet implements KernelExpression {
  KernelPropertySet(Expression receiver, Name name, Expression value,
      [Member interfaceTarget])
      : super(receiver, name, value, interfaceTarget);

  KernelPropertySet.byReference(Expression receiver, Name name,
      Expression value, Reference interfaceTargetReference)
      : super.byReference(receiver, name, value, interfaceTargetReference);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Assignment expressions are not immediately evident expressions.
    collector.recordNotImmediatelyEvident(fileOffset);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.propertySetEnter(this, typeContext) || typeNeeded;
    // First infer the receiver so we can look up the setter that was invoked.
    var receiverType = inferrer.inferExpression(receiver, null, true);
    Member interfaceMember;
    if (receiverType is InterfaceType) {
      interfaceMember = inferrer.classHierarchy
          .getInterfaceMember(receiverType.classNode, name, setter: true);
      // Our non-strong golden files currently don't include interface targets,
      // so we can't store the interface target without causing tests to fail.
      // TODO(paulberry): fix this.
      if (inferrer.strongMode) {
        inferrer.instrumentation?.record(Uri.parse(inferrer.uri), fileOffset,
            'target', new InstrumentationValueForMember(interfaceMember));
        interfaceTarget = interfaceMember;
      }
    }
    var setterType =
        inferrer.getSetterType(interfaceMember, receiverType, name);
    var inferredType = inferrer.inferExpression(value, setterType, typeNeeded);
    inferrer.listener.propertySetExit(this, inferredType);
    return typeNeeded ? inferredType : null;
  }
}

/// Concrete shadow object representing a redirecting initializer in kernel
/// form.
class KernelRedirectingInitializer extends RedirectingInitializer
    implements KernelInitializer {
  KernelRedirectingInitializer(Constructor target, Arguments arguments)
      : super(target, arguments);

  @override
  _inferInitializer(KernelTypeInferrer inferrer) {
    inferrer.listener.redirectingInitializerEnter(this);
    inferrer.inferInvocation(null, false, fileOffset,
        target.function.functionType, target.enclosingClass.thisType, arguments,
        skipTypeArgumentInference: true);
    inferrer.listener.redirectingInitializerExit(this);
  }
}

/// Shadow object for [Rethrow].
class KernelRethrow extends Rethrow implements KernelExpression {
  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Concrete shadow object representing a return statement in kernel form.
class KernelReturnStatement extends ReturnStatement implements KernelStatement {
  KernelReturnStatement([Expression expression]) : super(expression);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.returnStatementEnter(this);
    var closureContext = inferrer.closureContext;
    var typeContext =
        !closureContext.isGenerator ? closureContext.returnContext : null;
    var inferredType = expression != null
        ? inferrer.inferExpression(expression, typeContext, true)
        : const VoidType();
    // Analyzer treats bare `return` statements as having no effect on the
    // inferred type of the closure.  TODO(paulberry): is this what we want
    // for Fasta?
    if (expression != null) {
      closureContext.handleReturn(inferrer, inferredType);
    }
    inferrer.listener.returnStatementExit(this);
  }
}

/// Common base class for shadow objects representing statements in kernel
/// form.
abstract class KernelStatement extends Statement {
  /// Calls back to [inferrer] to perform type inference for whatever concrete
  /// type of [KernelStatement] this is.
  void _inferStatement(KernelTypeInferrer inferrer);
}

/// Concrete shadow object representing a read of a static variable in kernel
/// form.
class KernelStaticGet extends StaticGet implements KernelExpression {
  KernelStaticGet(Member target) : super(target);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // A simple or qualified identifier referring to a top level function,
    // static variable, field, getter; or a static class variable, static getter
    // or method; or an instance method; has the inferred type of the referent.
    // - Otherwise, if the identifier has no inferred or annotated type then it
    //   is an error.
    // - Note: specifically, references to instance fields and instance getters
    //   are disallowed here.
    // - The inference dependency of the identifier is the referent if the
    //   referent is a candidate for inference.  Otherwise there are no
    //   inference dependencies.
    // TODO(paulberry): implement the proper error checking logic.
    var target = this.target;
    if (target is KernelField && target._fieldNode != null) {
      collector.recordDependency(target._fieldNode);
    }
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.staticGetEnter(this, typeContext) || typeNeeded;
    var inferredType = typeNeeded ? target.getterType : null;
    inferrer.listener.staticGetExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [StaticInvocation].
class KernelStaticInvocation extends StaticInvocation
    implements KernelExpression {
  KernelStaticInvocation(Procedure target, Arguments arguments,
      {bool isConst: false})
      : super(target, arguments, isConst: isConst);

  KernelStaticInvocation.byReference(
      Reference targetReference, Arguments arguments)
      : super.byReference(targetReference, arguments);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded = inferrer.listener.staticInvocationEnter(this, typeContext) ||
        typeNeeded;
    var calleeType = target.function.functionType;
    var inferredType = inferrer.inferInvocation(typeContext, typeNeeded,
        fileOffset, calleeType, calleeType.returnType, arguments);
    inferrer.listener.staticInvocationExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [StaticSet].
class KernelStaticSet extends StaticSet implements KernelExpression {
  KernelStaticSet(Member target, Expression value) : super(target, value);

  KernelStaticSet.byReference(Reference targetReference, Expression value)
      : super.byReference(targetReference, value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Assignment expressions are not immediately evident expressions.
    collector.recordNotImmediatelyEvident(fileOffset);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Concrete shadow object representing a string concatenation in kernel form.
class KernelStringConcatenation extends StringConcatenation
    implements KernelExpression {
  KernelStringConcatenation(List<Expression> expressions) : super(expressions);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.stringConcatenationEnter(this, typeContext) ||
            typeNeeded;
    if (!inferrer.isTopLevel) {
      for (Expression expression in expressions) {
        inferrer.inferExpression(expression, null, false);
      }
    }
    var inferredType =
        typeNeeded ? inferrer.coreTypes.stringClass.rawType : null;
    inferrer.listener.stringConcatenationExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a string literal in kernel form.
class KernelStringLiteral extends StringLiteral implements KernelExpression {
  KernelStringLiteral(String value) : super(value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    typeNeeded =
        inferrer.listener.stringLiteralEnter(this, typeContext) || typeNeeded;
    var inferredType =
        typeNeeded ? inferrer.coreTypes.stringClass.rawType : null;
    inferrer.listener.stringLiteralExit(this, inferredType);
    return inferredType;
  }
}

/// Shadow object for [SuperMethodInvocation].
class KernelSuperMethodInvocation extends SuperMethodInvocation
    implements KernelExpression {
  KernelSuperMethodInvocation(Name name, Arguments arguments,
      [Procedure interfaceTarget])
      : super(name, arguments, interfaceTarget);

  KernelSuperMethodInvocation.byReference(
      Name name, Arguments arguments, Reference interfaceTargetReference)
      : super.byReference(name, arguments, interfaceTargetReference);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Super expressions should never occur in top level type inference.
    // TODO(paulberry): but could they occur due to invalid code?
    assert(false);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [SuperPropertyGet].
class KernelSuperPropertyGet extends SuperPropertyGet
    implements KernelExpression {
  KernelSuperPropertyGet(Name name, [Member interfaceTarget])
      : super(name, interfaceTarget);

  KernelSuperPropertyGet.byReference(
      Name name, Reference interfaceTargetReference)
      : super.byReference(name, interfaceTargetReference);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Super expressions should never occur in top level type inference.
    // TODO(paulberry): but could they occur due to invalid code?
    assert(false);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [SuperPropertySet].
class KernelSuperPropertySet extends SuperPropertySet
    implements KernelExpression {
  KernelSuperPropertySet(Name name, Expression value, Member interfaceTarget)
      : super(name, value, interfaceTarget);

  KernelSuperPropertySet.byReference(
      Name name, Expression value, Reference interfaceTargetReference)
      : super.byReference(name, value, interfaceTargetReference);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Assignment expressions are not immediately evident expressions.
    collector.recordNotImmediatelyEvident(fileOffset);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [SymbolLiteral].
class KernelSymbolLiteral extends SymbolLiteral implements KernelExpression {
  KernelSymbolLiteral(String value) : super(value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [ThisExpression].
class KernelThisExpression extends ThisExpression implements KernelExpression {
  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // TODO(paulberry): figure out the right thing to do here.
    throw 'TODO(paulberry)';
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Shadow object for [Throw].
class KernelThrow extends Throw implements KernelExpression {
  KernelThrow(Expression expression) : super(expression);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    inferrer.inferExpression(expression, null, false);
    return typeNeeded ? const BottomType() : null;
  }
}

/// Concrete implementation of [TypeInferenceEngine] specialized to work with
/// kernel objects.
class KernelTypeInferenceEngine extends TypeInferenceEngineImpl {
  KernelTypeInferenceEngine(Instrumentation instrumentation, bool strongMode)
      : super(instrumentation, strongMode);

  @override
  void clearFieldInitializer(KernelField field) {
    field.initializer = null;
  }

  @override
  FieldNode createFieldNode(KernelField field) {
    FieldNode fieldNode = new FieldNode(this, field);
    field._fieldNode = fieldNode;
    return fieldNode;
  }

  @override
  KernelTypeInferrer createLocalTypeInferrer(
      Uri uri, TypeInferenceListener listener) {
    return new KernelTypeInferrer._(this, uri.toString(), listener, false);
  }

  @override
  KernelTypeInferrer createTopLevelTypeInferrer(
      KernelField field, TypeInferenceListener listener) {
    return field._typeInferrer =
        new KernelTypeInferrer._(this, getFieldUri(field), listener, true);
  }

  @override
  bool fieldHasInitializer(KernelField field) {
    return field.initializer != null;
  }

  @override
  DartType getFieldDeclaredType(KernelField field) {
    return field._implicitlyTyped ? null : field.type;
  }

  @override
  int getFieldOffset(KernelField field) {
    return field.fileOffset;
  }

  @override
  KernelTypeInferrer getFieldTypeInferrer(KernelField field) {
    return field._typeInferrer;
  }

  @override
  String getFieldUri(KernelField field) {
    return field._fileUri;
  }

  @override
  bool isFieldInferred(KernelField field) {
    return field._isInferred;
  }

  @override
  void setFieldInferredType(KernelField field, DartType inferredType) {
    field._setInferredType(inferredType);
  }
}

/// Concrete implementation of [TypeInferrer] specialized to work with kernel
/// objects.
class KernelTypeInferrer extends TypeInferrerImpl {
  @override
  final typePromoter = new KernelTypePromoter();

  KernelTypeInferrer._(KernelTypeInferenceEngine engine, String uri,
      TypeInferenceListener listener, bool topLevel)
      : super(engine, uri, listener, topLevel);

  @override
  Expression getFieldInitializer(KernelField field) {
    return field.initializer;
  }

  @override
  DartType inferExpression(
      Expression expression, DartType typeContext, bool typeNeeded) {
    if (expression is KernelExpression) {
      // Use polymorphic dispatch on [KernelExpression] to perform whatever kind
      // of type inference is correct for this kind of statement.
      // TODO(paulberry): experiment to see if dynamic dispatch would be better,
      // so that the type hierarchy will be simpler (which may speed up "is"
      // checks).
      return expression._inferExpression(this, typeContext, typeNeeded);
    } else {
      // Encountered an expression type for which type inference is not yet
      // implemented, so just infer dynamic for now.
      // TODO(paulberry): once the BodyBuilder uses shadow classes for
      // everything, this case should no longer be needed.
      return typeNeeded ? const DynamicType() : null;
    }
  }

  @override
  DartType inferFieldTopLevel(
      KernelField field, DartType type, bool typeNeeded) {
    return inferExpression(field.initializer, type, typeNeeded);
  }

  @override
  void inferInitializer(Initializer initializer) {
    if (initializer is KernelInitializer) {
      // Use polymorphic dispatch on [KernelInitializer] to perform whatever
      // kind of type inference is correct for this kind of initializer.
      // TODO(paulberry): experiment to see if dynamic dispatch would be better,
      // so that the type hierarchy will be simpler (which may speed up "is"
      // checks).
      return initializer._inferInitializer(this);
    } else {
      // Encountered an initializer type for which type inference is not yet
      // implemented, so just skip it for now.
      // TODO(paulberry): once the BodyBuilder uses shadow classes for
      // everything, this case should no longer be needed.
    }
  }

  @override
  void inferStatement(Statement statement) {
    if (statement is KernelStatement) {
      // Use polymorphic dispatch on [KernelStatement] to perform whatever kind
      // of type inference is correct for this kind of statement.
      // TODO(paulberry): experiment to see if dynamic dispatch would be better,
      // so that the type hierarchy will be simpler (which may speed up "is"
      // checks).
      return statement._inferStatement(this);
    } else {
      // Encountered a statement type for which type inference is not yet
      // implemented, so just skip it for now.
      // TODO(paulberry): once the BodyBuilder uses shadow classes for
      // everything, this case should no longer be needed.
    }
  }
}

/// Shadow object for [TypeLiteral].
class KernelTypeLiteral extends TypeLiteral implements KernelExpression {
  KernelTypeLiteral(DartType type) : super(type);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    // TODO(scheglov): implement.
    return typeNeeded ? const DynamicType() : null;
  }
}

/// Concrete implementation of [TypePromoter] specialized to work with kernel
/// objects.
///
/// Note: the second type parameter really ought to be
/// KernelVariableDeclaration, but we can't do that yet because BodyBuilder
/// still uses raw VariableDeclaration objects sometimes.
/// TODO(paulberry): fix this.
class KernelTypePromoter
    extends TypePromoterImpl<Expression, VariableDeclaration> {
  @override
  int getVariableFunctionNestingLevel(VariableDeclaration variable) {
    if (variable is KernelVariableDeclaration) {
      return variable._functionNestingLevel;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
      return 0;
    }
  }

  @override
  bool isPromotionCandidate(VariableDeclaration variable) {
    if (variable is KernelVariableDeclaration) {
      return !variable._isLocalFunction;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
      return true;
    }
  }

  @override
  bool sameExpressions(Expression a, Expression b) {
    return identical(a, b);
  }

  @override
  void setVariableMutatedAnywhere(VariableDeclaration variable) {
    if (variable is KernelVariableDeclaration) {
      variable._mutatedAnywhere = true;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
    }
  }

  @override
  void setVariableMutatedInClosure(VariableDeclaration variable) {
    if (variable is KernelVariableDeclaration) {
      variable._mutatedInClosure = true;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
    }
  }

  @override
  bool wasVariableMutatedAnywhere(VariableDeclaration variable) {
    if (variable is KernelVariableDeclaration) {
      return variable._mutatedAnywhere;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
      return true;
    }
  }
}

/// Concrete shadow object representing a variable declaration in kernel form.
class KernelVariableDeclaration extends VariableDeclaration
    implements KernelStatement {
  final bool _implicitlyTyped;

  final int _functionNestingLevel;

  bool _mutatedInClosure = false;

  bool _mutatedAnywhere = false;

  final bool _isLocalFunction;

  KernelVariableDeclaration(String name, this._functionNestingLevel,
      {Expression initializer,
      DartType type,
      bool isFinal: false,
      bool isConst: false,
      bool isLocalFunction: false})
      : _implicitlyTyped = type == null,
        _isLocalFunction = isLocalFunction,
        super(name,
            initializer: initializer,
            type: type ?? const DynamicType(),
            isFinal: isFinal,
            isConst: isConst);

  KernelVariableDeclaration.forValue(
      Expression initializer, this._functionNestingLevel)
      : _implicitlyTyped = true,
        _isLocalFunction = false,
        super.forValue(initializer);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.variableDeclarationEnter(this);
    var declaredType = _implicitlyTyped ? null : type;
    if (initializer != null) {
      var inferredType = inferrer.inferDeclarationType(inferrer.inferExpression(
          initializer, declaredType, _implicitlyTyped));
      if (inferrer.strongMode && _implicitlyTyped) {
        inferrer.instrumentation?.record(Uri.parse(inferrer.uri), fileOffset,
            'type', new InstrumentationValueForType(inferredType));
        type = inferredType;
      }
    }
    inferrer.listener.variableDeclarationExit(this);
  }

  /// Determine whether the given [KernelVariableDeclaration] had an implicit
  /// type.
  ///
  /// This is static to avoid introducing a method that would be visible to
  /// the kernel.
  static bool isImplicitlyTyped(KernelVariableDeclaration variable) =>
      variable._implicitlyTyped;
}

/// Concrete shadow object representing a read from a variable in kernel form.
class KernelVariableGet extends VariableGet implements KernelExpression {
  final TypePromotionFact<VariableDeclaration> _fact;

  final TypePromotionScope _scope;

  KernelVariableGet(VariableDeclaration variable, this._fact, this._scope)
      : super(variable);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // No inference dependencies.
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    var variable = this.variable as KernelVariableDeclaration;
    bool mutatedInClosure = variable._mutatedInClosure;
    DartType declaredOrInferredType = variable.type;
    typeNeeded =
        inferrer.listener.variableGetEnter(this, typeContext) || typeNeeded;
    DartType promotedType = inferrer.typePromoter
        .computePromotedType(_fact, _scope, mutatedInClosure);
    if (promotedType != null) {
      inferrer.instrumentation?.record(Uri.parse(inferrer.uri), fileOffset,
          'promotedType', new InstrumentationValueForType(promotedType));
    }
    this.promotedType = promotedType;
    var inferredType =
        typeNeeded ? (promotedType ?? declaredOrInferredType) : null;
    inferrer.listener.variableGetExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a write to a variable in kernel form.
class KernelVariableSet extends VariableSet implements KernelExpression {
  KernelVariableSet(VariableDeclaration variable, Expression value)
      : super(variable, value);

  @override
  void _collectDependencies(KernelDependencyCollector collector) {
    // Assignment expressions are not immediately evident expressions.
    collector.recordNotImmediatelyEvident(fileOffset);
  }

  @override
  DartType _inferExpression(
      KernelTypeInferrer inferrer, DartType typeContext, bool typeNeeded) {
    var variable = this.variable as KernelVariableDeclaration;
    typeNeeded =
        inferrer.listener.variableSetEnter(this, typeContext) || typeNeeded;
    var inferredType =
        inferrer.inferExpression(value, variable.type, typeNeeded);
    inferrer.listener.variableSetExit(this, inferredType);
    return inferredType;
  }
}

/// Concrete shadow object representing a yield statement in kernel form.
class KernelYieldStatement extends YieldStatement implements KernelStatement {
  KernelYieldStatement(Expression expression, {bool isYieldStar: false})
      : super(expression, isYieldStar: isYieldStar);

  @override
  void _inferStatement(KernelTypeInferrer inferrer) {
    inferrer.listener.yieldStatementEnter(this);
    var closureContext = inferrer.closureContext;
    var typeContext =
        closureContext.isGenerator ? closureContext.returnContext : null;
    if (isYieldStar && typeContext != null) {
      typeContext = inferrer.wrapType(
          typeContext,
          closureContext.isAsync
              ? inferrer.coreTypes.streamClass
              : inferrer.coreTypes.iterableClass);
    }
    var inferredType = inferrer.inferExpression(
        expression, typeContext, closureContext != null);
    closureContext.handleYield(inferrer, isYieldStar, inferredType);
    inferrer.listener.yieldStatementExit(this);
  }
}

class _UnfinishedCascade extends Expression {
  accept(v) {
    return internalError("Internal error: Unsupported operation.");
  }

  accept1(v, arg) {
    return internalError("Internal error: Unsupported operation.");
  }

  getStaticType(types) {
    return internalError("Internal error: Unsupported operation.");
  }

  transformChildren(v) {
    return internalError("Internal error: Unsupported operation.");
  }

  visitChildren(v) {
    return internalError("Internal error: Unsupported operation.");
  }
}
