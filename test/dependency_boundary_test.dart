/// The airlock is the security core: a module that writes requests for a
/// chat service is outside it, so the airlock never depends on one by
/// name (Nick's ruling, 28 Nov — a `*_module` import ties every airlock
/// release to a module's own tag, and puts chat-service code where it must
/// not run). This test stops it coming back, the same way
/// is_conversation_vocabulary's test/dependency_boundary_test.dart guards
/// its own narrower boundary.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Every URI a source's directives name, in every branch, as written. See
/// is_conversation_vocabulary's own copy of this for why: the parse tree
/// keeps every branch of a conditional import, which the element model
/// does not.
Iterable<StringLiteral> _directiveUris(String source) sync* {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  for (final directive in unit.directives) {
    yield* switch (directive) {
      NamespaceDirective(:final uri, :final configurations) => [
        uri,
        for (final branch in configurations) branch.uri,
      ],
      PartDirective(:final uri) => [uri],
      LibraryDirective() || PartOfDirective() => const <StringLiteral>[],
    };
  }
}

/// Whether [packageName] is a module's: ends in `_module`.
bool _isModulePackage(String packageName) => packageName.endsWith('_module');

void main() {
  test('pubspec.yaml names no *_module dependency', () {
    // cast-ok: pubspec.yaml's own top level is always a map.
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final names = [
      for (final section in ['dependencies', 'dev_dependencies'])
        if (pubspec[section] case final YamlMap deps) ...deps.keys.cast<String>(),
    ];
    final violations = names.where(_isModulePackage);
    expect(
      violations,
      isEmpty,
      reason: 'the airlock depends on no module — it writes its own replies',
    );
  });

  test('no Dart file under lib/ or bin/ imports a *_module package', () {
    final violations = <String>[];
    for (final dir in ['lib', 'bin']) {
      if (!Directory(dir).existsSync()) continue;
      for (final file in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        for (final literal in _directiveUris(file.readAsStringSync())) {
          final target = literal.stringValue;
          if (target == null) continue;
          final uri = Uri.parse(target);
          if (uri.scheme == 'package' &&
              _isModulePackage(uri.pathSegments.first)) {
            violations.add('${file.path}: $target');
          }
        }
      }
    }
    expect(violations, isEmpty);
  });
}
