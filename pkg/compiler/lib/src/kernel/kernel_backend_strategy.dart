// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.kernel.backend_strategy;

import 'package:kernel/ast.dart' as ir;

import '../backend_strategy.dart';
import '../closure.dart';
import '../common/codegen.dart' show CodegenRegistry, CodegenWorkItem;
import '../common/tasks.dart';
import '../compiler.dart';
import '../elements/entities.dart';
import '../elements/entity_utils.dart' as utils;
import '../enqueue.dart';
import '../io/source_information.dart';
import '../js/js_source_mapping.dart';
import '../js_backend/backend.dart';
import '../js_backend/native_data.dart';
import '../js_emitter/sorter.dart';
import '../kernel/element_map.dart';
import '../kernel/element_map_impl.dart';
import '../native/behavior.dart';
import '../ssa/builder_kernel.dart';
import '../ssa/nodes.dart';
import '../ssa/ssa.dart';
import '../ssa/types.dart';
import '../types/types.dart';
import '../universe/selector.dart';
import '../universe/world_builder.dart';
import '../universe/world_impact.dart';
import '../world.dart';
import 'element_map_impl.dart';
import 'kernel_strategy.dart';

/// Backend strategy that uses the kernel elements as the backend model.
// TODO(johnniwinther): Replace this with a strategy based on the J-element
// model.
class KernelBackendStrategy implements BackendStrategy {
  final Compiler _compiler;
  Sorter _sorter;

  KernelBackendStrategy(this._compiler);

  @override
  ClosedWorldRefiner createClosedWorldRefiner(KernelClosedWorld closedWorld) {
    return closedWorld;
  }

  @override
  Sorter get sorter {
    if (_sorter == null) {
      KernelFrontEndStrategy frontEndStrategy = _compiler.frontEndStrategy;
      _sorter = new KernelSorter(frontEndStrategy.elementMap);
    }
    return _sorter;
  }

  @override
  void convertClosures(ClosedWorldRefiner closedWorldRefiner) {
    // TODO(johnniwinther,efortuna): Compute closure classes for kernel based
    // elements.
  }

  @override
  WorkItemBuilder createCodegenWorkItemBuilder(ClosedWorld closedWorld) {
    return new KernelCodegenWorkItemBuilder(_compiler.backend, closedWorld);
  }

  @override
  CodegenWorldBuilder createCodegenWorldBuilder(
      NativeBasicData nativeBasicData,
      ClosedWorld closedWorld,
      SelectorConstraintsStrategy selectorConstraintsStrategy) {
    return new KernelCodegenWorldBuilder(_compiler.elementEnvironment,
        nativeBasicData, closedWorld, selectorConstraintsStrategy);
  }

  @override
  SsaBuilderTask createSsaBuilderTask(JavaScriptBackend backend,
      SourceInformationStrategy sourceInformationStrategy) {
    return new KernelSsaBuilderTask(backend.compiler);
  }

  @override
  SourceInformationStrategy get sourceInformationStrategy =>
      const JavaScriptSourceInformationStrategy();
}

class KernelCodegenWorkItemBuilder implements WorkItemBuilder {
  final JavaScriptBackend _backend;
  final ClosedWorld _closedWorld;

  KernelCodegenWorkItemBuilder(this._backend, this._closedWorld);

  @override
  CodegenWorkItem createWorkItem(MemberEntity entity) {
    return new KernelCodegenWorkItem(_backend, _closedWorld, entity);
  }
}

class KernelCodegenWorkItem extends CodegenWorkItem {
  final JavaScriptBackend _backend;
  final ClosedWorld _closedWorld;
  final MemberEntity element;
  final CodegenRegistry registry;

  KernelCodegenWorkItem(this._backend, this._closedWorld, this.element)
      : registry = new CodegenRegistry(element);

  @override
  WorldImpact run() {
    return _backend.codegen(this, _closedWorld);
  }
}

/// Task for building SSA from kernel IR loaded from .dill.
class KernelSsaBuilderTask extends CompilerTask implements SsaBuilderTask {
  final Compiler _compiler;

  KernelSsaBuilderTask(this._compiler) : super(_compiler.measurer);

  KernelToElementMapImpl get _elementMap {
    KernelFrontEndStrategy frontEndStrategy = _compiler.frontEndStrategy;
    return frontEndStrategy.elementMap;
  }

  @override
  HGraph build(CodegenWorkItem work, ClosedWorld closedWorld) {
    KernelSsaBuilder builder = new KernelSsaBuilder(
        work.element,
        work.element.enclosingClass,
        _elementMap.getMemberNode(work.element),
        _compiler,
        _elementMap,
        new KernelToTypeInferenceMapImpl(closedWorld),
        closedWorld,
        work.registry,
        // TODO(johnniwinther): Support these:
        const KernelClosureClassMaps(),
        const SourceInformationBuilder(),
        null, // Function node used as capture scope id.
        targetIsConstructorBody: false);
    return builder.build();
  }
}

class KernelToTypeInferenceMapImpl implements KernelToTypeInferenceMap {
  final ClosedWorld _closedWorld;

  KernelToTypeInferenceMapImpl(this._closedWorld);

  @override
  TypeMask typeFromNativeBehavior(
      NativeBehavior nativeBehavior, ClosedWorld closedWorld) {
    return TypeMaskFactory.fromNativeBehavior(nativeBehavior, closedWorld);
  }

  @override
  TypeMask selectorTypeOf(Selector selector, TypeMask mask) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask getInferredTypeOf(MemberEntity member) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask inferredIndexType(ir.ForInStatement forInStatement) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  bool isJsIndexableIterator(
      ir.ForInStatement forInStatement, ClosedWorld closedWorld) {
    return false;
  }

  @override
  TypeMask typeOfIteratorMoveNext(ir.ForInStatement forInStatement) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask typeOfIteratorCurrent(ir.ForInStatement forInStatement) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask typeOfIterator(ir.ForInStatement forInStatement) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask typeOfListLiteral(
      MemberEntity owner, ir.ListLiteral listLiteral, ClosedWorld closedWorld) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask typeOfSet(ir.PropertySet write, ClosedWorld closedWorld) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask typeOfGet(ir.PropertyGet read) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask typeOfInvocation(
      ir.MethodInvocation invocation, ClosedWorld closedWorld) {
    return _closedWorld.commonMasks.dynamicType;
  }

  @override
  TypeMask getReturnTypeOf(FunctionEntity function) {
    return _closedWorld.commonMasks.dynamicType;
  }
}

/// TODO(johnniwinther,efortuna): Implement this.
class KernelClosureClassMaps implements ClosureClassMaps {
  const KernelClosureClassMaps();

  @override
  ClosureClassMap getLocalFunctionMap(Local localFunction) {
    return new ClosureClassMap(null, null, null, null);
  }

  @override
  ClosureClassMap getMemberMap(MemberEntity member) {
    return new ClosureClassMap(null, null, null, null);
  }
}

class KernelSorter implements Sorter {
  final KernelToElementMapImpl elementMap;

  KernelSorter(this.elementMap);

  int _compareLibraries(LibraryEntity a, LibraryEntity b) {
    return utils.compareLibrariesUris(a.canonicalUri, b.canonicalUri);
  }

  int _compareNodes(
      Entity entity1, ir.TreeNode node1, Entity entity2, ir.TreeNode node2) {
    ir.Location location1 = node1.location;
    ir.Location location2 = node2.location;
    int r = utils.compareSourceUris(
        Uri.parse(location1.file), Uri.parse(location2.file));
    if (r != 0) return r;
    return utils.compareEntities(entity1, location1.line, location1.column,
        entity2, location2.line, location2.column);
  }

  @override
  Iterable<LibraryEntity> sortLibraries(Iterable<LibraryEntity> libraries) {
    return libraries.toList()..sort(_compareLibraries);
  }

  @override
  Iterable<MemberEntity> sortMembers(Iterable<MemberEntity> members) {
    return members.toList()
      ..sort((MemberEntity a, MemberEntity b) {
        int r = _compareLibraries(a.library, b.library);
        if (r != 0) return r;
        return _compareNodes(
            a, elementMap.getMemberNode(a), b, elementMap.getMemberNode(b));
      });
  }

  @override
  Iterable<ClassEntity> sortClasses(Iterable<ClassEntity> classes) {
    return classes.toList()
      ..sort((ClassEntity a, ClassEntity b) {
        int r = _compareLibraries(a.library, b.library);
        if (r != 0) return r;
        return _compareNodes(
            a, elementMap.getClassNode(a), b, elementMap.getClassNode(b));
      });
  }
}
