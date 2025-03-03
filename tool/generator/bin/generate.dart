import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:generator/generator.dart';
import 'package:winmd/winmd.dart';

import 'generate_struct_sizes_cpp.dart';

bool methodMatches(String methodName, String rawPrototype) =>
    rawPrototype.contains(' $methodName(');

String generateDocComment(Win32Function func, String libraryDartName) {
  final category = func.category.isNotEmpty ? func.category : libraryDartName;

  final comment = StringBuffer();

  if (func.comment.isNotEmpty) {
    comment
      ..writeln(wrapCommentText(func.comment))
      ..writeln('///');
  }

  comment
    ..writeln('/// ```c')
    ..write('/// ')
    ..writeln(func.prototype.split('\\n').join('\n/// '))
    ..writeln('/// ```')
    ..write('/// {@category $category}');
  return comment.toString();
}

int generateStructs(Map<String, String> structs) {
  final scope = MetadataStore.getWin32Scope();

  final file = File('../../lib/src/structs.g.dart');

  final typeDefs = scope.typeDefs
      .where((typeDef) => structs.keys.contains(typeDef.name))
      .where((typeDef) => typeDef.supportedArchitectures.x64)
      .toList()
    ..sort((a, b) => lastComponent(a.name).compareTo(lastComponent(b.name)));

  final structProjections = typeDefs.map((struct) => StructProjection(
      struct, stripAnsiUnicodeSuffix(lastComponent(struct.name)),
      comment: structs[struct.name]!));

  final structsFile = [structFileHeader, ...structProjections].join();

  file.writeAsStringSync(DartFormatter().format(structsFile));
  return structProjections.length;
}

int generateStructSizeTests() {
  var testsGenerated = 0;
  final buffer = StringBuffer()..write('''
$testStructsHeader

void main() {
  final is64bitOS = sizeOf<IntPtr>() == 8;
''');

  for (final struct in structSize64.keys) {
    if (structSize64[struct] == structSize32[struct]) {
      buffer.write('''
  test('Struct $struct is the right size', () {
    expect(sizeOf<$struct>(), equals(${structSize64[struct]}));
  });
    ''');
    } else {
      buffer.write('''
  test('Struct $struct is the right size', () {
    if (is64bitOS) {
      expect(sizeOf<$struct>(), equals(${structSize64[struct]}));
    }
    else {
      expect(sizeOf<$struct>(), equals(${structSize32[struct]}));
    }
  });
''');
    }
    testsGenerated++;
  }

  buffer.write('}');

  File('../../test/struct_test.dart')
      .writeAsStringSync(DartFormatter().format(buffer.toString()));

  return testsGenerated;
}

void generateDllFile(String library, List<Method> filteredMethods,
    Iterable<Win32Function> functions) {
  /// Methods we're trying to project
  final libraryMethods = filteredMethods
      .where((method) => method.module.name.toLowerCase() == library);

  final buffer = StringBuffer();

  // API set names aren't legal Dart identifiers, so we rename them.
  // Also strip off the trailing .dll (or .cpl, .drv, etc.).
  final libraryDartName = library.replaceAll('-', '_').split('.').first;

  buffer.write('''
  $functionsFileHeader

  final _$libraryDartName = DynamicLibrary.open('$library');\n
  ''');

  for (final method in libraryMethods) {
    final function =
        functions.firstWhere((f) => f.functionSymbol == method.name);
    buffer.write('''
  ${generateDocComment(function, libraryDartName)}
  ${FunctionProjection(method, libraryDartName).toString()}
  ''');
  }

  File('../../lib/src/win32/$libraryDartName.g.dart')
      .writeAsStringSync(DartFormatter().format(buffer.toString()));
}

void generateFunctions(Map<String, Win32Function> functions) {
  final scope = MetadataStore.getWin32Scope();
  final apis = scope.typeDefs.where((typeDef) => typeDef.name.endsWith('Apis'));

  final methods = <Method>[];
  final filteredMethods = <Method>[];

  // Create a flat list for every method in the Win32 metadata, and a set
  // containing all the modules (DLLs) referenced.
  for (final api in apis) {
    methods.addAll(api.methods);
  }

  // Gather metadata for all the functions in the JSON file
  for (final function in functions.values) {
    final method = methods.where((m) => m.name == function.functionSymbol);
    if (method.length != 1) {
      throw Exception('${function.functionSymbol} metadata match error.');
    }
    filteredMethods.add(method.first);
  }

  // Gather a list of all the affected libraries
  final dllLibraries =
      filteredMethods.map((m) => m.module.name.toLowerCase()).toSet();

  final tests = <String>[];

  for (final library in dllLibraries) {
    generateDllFile(library, filteredMethods, functions.values);
    tests
        .add(generateFunctionTests(library, filteredMethods, functions.values));
  }

  writeFunctionTests(tests);
}

void writeFunctionTests(Iterable<String> tests) {
  final testFile = '''
$testFunctionsHeader

import 'helpers.dart';

void main() {
  final windowsBuildNumber = getWindowsBuildNumber();
  ${tests.join('\n')}
}
''';

  File('../../test/api_test.dart')
      .writeAsStringSync(DartFormatter().format(testFile));
}

String generateFunctionTests(String library, Iterable<Method> methods,
    Iterable<Win32Function> functions) {
  final buffer = StringBuffer();

  // GitHub Actions doesn't install Native Wifi API on runners, so we remove
  // wlanapi manually to prevent test failures.
  if (library == 'wlanapi.dll') return '';

  /// Methods we're trying to project
  final filteredMethods =
      methods.where((method) => method.module.name.toLowerCase() == library);

  buffer.write("group('Test ${library.split('.').first} functions', () {\n");

  for (final method in filteredMethods) {
    // API set names aren't legal Dart identifiers, so we rename them.
    // Also strip off the trailing .dll (or .cpl, .drv, etc.).
    final libraryDartName = library.replaceAll('-', '_').split('.').first;

    final function =
        functions.firstWhere((f) => f.functionSymbol == method.name);

    // Some functions (e.g. TaskDialog APIs) can only be loaded if the EXE has a
    // manifest, so we ignore those for the purpose of test generation.
    if (!function.test) continue;

    final projection = FunctionProjection(method, libraryDartName);

    final returnFFIType =
        TypeProjection(method.returnType.typeIdentifier).nativeType;
    final returnDartType =
        TypeProjection(method.returnType.typeIdentifier).dartType;

    final methodDartName = stripAnsiUnicodeSuffix(method.name);

    final test = '''
      test('Can instantiate $methodDartName', () {
        final $libraryDartName = DynamicLibrary.open('$library');
        final $methodDartName = $libraryDartName.lookupFunction<\n
          $returnFFIType Function(${projection.nativeParams}),
          $returnDartType Function(${projection.dartParams})>
          ('${method.name}');
        expect($methodDartName, isA<Function>());
      });''';

    if (function.minimumWindowsVersion > 0) {
      buffer.writeln('''
          if (windowsBuildNumber >= ${function.minimumWindowsVersion}) {
            $test
          }''');
    } else {
      buffer.writeln(test);
    }
  }
  buffer.write('});\n\n');

  return buffer.toString();
}

void generateComApis(Map<String, String> comTypesToGenerate) {
  final scope = MetadataStore.getWin32Scope();

  for (final interface in comTypesToGenerate.keys) {
    final typeDef = scope.findTypeDef(interface);
    if (typeDef == null) throw Exception("Can't find $interface");
    final interfaceProjection =
        ComInterfaceProjection(typeDef, comTypesToGenerate[interface] ?? '');

    // In v2, we put classes and interfaces in the same file.
    final className = ComClassProjection.generateClassName(typeDef);
    final classNameExists = scope.findTypeDef(className) != null;

    final comObject = classNameExists
        ? ComClassProjection.fromInterface(typeDef)
        : interfaceProjection;

    // Generate class
    final dartClass = comObject.toString();
    final classOutputFilename =
        stripAnsiUnicodeSuffix(lastComponent(interface)).toLowerCase();
    final classOutputPath = '../../lib/src/com/$classOutputFilename.dart';

    File(classOutputPath).writeAsStringSync(DartFormatter().format(dartClass));

    // Generate test
    final dartTest = TestInterfaceProjection(typeDef, interfaceProjection);
    final testOutputPath = '../../test/com/${classOutputFilename}_test.dart';

    File(testOutputPath)
        .writeAsStringSync(DartFormatter().format(dartTest.toString()));
  }
}

void generateWinRTApis(Map<String, String> typesToGenerate) {
  // Catalog all the types we need to generate: the types themselves and their
  // dependencies
  final typesAndDependencies = <String>{};
  for (final type in typesToGenerate.keys) {
    final typeDef = MetadataStore.getMetadataForType(type);
    if (typeDef == null) throw Exception("Can't find $type");
    final projection = typeDef.isInterface
        ? WinRTInterfaceProjection(typeDef)
        : WinRTClassProjection(typeDef);

    typesAndDependencies.addAll({
      // The type itself, e.g. 'Windows.Globalization.Calendar'
      type,

      // Interfaces that the type implements e.g.'Windows.Globalization.ICalendar'
      ...projection.typeDef.interfaces.map((interface) => interface.name),

      // The type's factory and static interfaces e.g.
      // 'Windows.Globalization.ICalendarFactory'
      if (projection is WinRTClassProjection) ...projection.factoryInterfaces,
      if (projection is WinRTClassProjection) ...projection.staticInterfaces
    });
  }

  typesAndDependencies
    // Remove generic interfaces (https://github.com/timsneath/win32/issues/480)
    ..removeWhere((type) => type.isEmpty)
    // Remove excluded WinRT types
    ..removeWhere((type) => excludedWindowsRuntimeTypes.contains(type));

  // Generate the type projection for each type
  for (final type in typesAndDependencies) {
    final typeDef = MetadataStore.getMetadataForType(type);
    if (typeDef == null) throw Exception("Can't find $type");
    final projection = typeDef.isInterface
        ? WinRTInterfaceProjection(typeDef, typesToGenerate[typeDef.name] ?? '')
        : WinRTClassProjection(typeDef, typesToGenerate[typeDef.name] ?? '');

    final dartClass = projection.toString();
    final classOutputPath =
        '../../lib/src/winrt/${filePathFromWinRTType(type)}';

    try {
      final formattedDartClass = DartFormatter().format(dartClass);
      File(classOutputPath)
        ..createSync(recursive: true)
        ..writeAsStringSync(formattedDartClass);
    } catch (_) {
      // Better to write even on failure, so we can figure out what syntax error
      // it was that thwarted DartFormatter.
      print('Unable to format class. Writing unformatted...');
      File(classOutputPath)
        ..createSync(recursive: true)
        ..writeAsStringSync(dartClass);
    }
  }
}

void generateWinRTEnumerations(Map<String, String> enums) {
  final namespaceGroups = groupTypesByParentNamespace(enums.keys);

  for (final namespaceGroup in namespaceGroups) {
    final enumProjections = <EnumProjection>[];
    final folderPath = folderFromWinRTType(namespaceGroup.types.first);
    final file = File('../../lib/src/winrt/$folderPath/enums.g.dart')
      ..createSync(recursive: true);

    for (final type in namespaceGroup.types) {
      final typeDef = MetadataStore.getMetadataForType(type);
      if (typeDef == null) throw Exception("Can't find $type");

      final EnumProjection enumProjection;
      if (typeDef.existsAttribute('System.FlagsAttribute')) {
        enumProjection = FlagsEnumProjection(
            typeDef, stripAnsiUnicodeSuffix(lastComponent(typeDef.name)),
            comment: enums[typeDef.name]!);
      } else {
        enumProjection = EnumProjection(
            typeDef, stripAnsiUnicodeSuffix(lastComponent(typeDef.name)),
            comment: enums[typeDef.name]!);
      }
      enumProjections.add(enumProjection);
    }

    enumProjections.sort((a, b) =>
        lastComponent(a.enumName).compareTo(lastComponent(b.enumName)));

    final winrtEnumFileImport =
        "import '${relativePath('winrt/foundation/winrt_enum.dart', start: 'winrt/$folderPath')}';";
    final enumsFile =
        [winrtEnumFileHeader, winrtEnumFileImport, ...enumProjections].join();
    file.writeAsStringSync(DartFormatter().format(enumsFile));
  }
}

void generateWinRTStructs(Map<String, String> structs) {
  final namespaceGroups = groupTypesByParentNamespace(structs.keys);

  for (final namespaceGroup in namespaceGroups) {
    final structProjections = <StructProjection>[];
    final folderPath = folderFromWinRTType(namespaceGroup.types.first);
    final file = File('../../lib/src/winrt/$folderPath/structs.g.dart')
      ..createSync(recursive: true);

    for (final type in namespaceGroup.types) {
      final typeDef = MetadataStore.getMetadataForType(type);
      if (typeDef == null) throw Exception("Can't find $type");

      final structProjection = StructProjection(
          typeDef, stripAnsiUnicodeSuffix(lastComponent(typeDef.name)),
          comment: structs[typeDef.name]!);
      structProjections.add(structProjection);
    }

    structProjections.sort((a, b) =>
        lastComponent(a.structName).compareTo(lastComponent(b.structName)));

    final structsFile = [winrtStructFileHeader, ...structProjections].join();
    file.writeAsStringSync(DartFormatter().format(structsFile));
  }
}

void main() {
  print('Loading and sorting functions...');
  final functionsToGenerate = loadFunctionsFromJson();
  saveFunctionsToJson(functionsToGenerate);

  print('Generating struct_sizes.cpp...');
  final structsToGenerate = loadMap('win32_structs.json');
  saveMap(structsToGenerate, 'win32_structs.json');
  generateStructSizeAnalyzer();

  print('Generating structs...');
  generateStructs(structsToGenerate);

  print('Generating struct tests...');
  generateStructSizeTests();

  print('Validating callbacks...');
  final callbacks = loadMap('win32_callbacks.json');
  saveMap(callbacks, 'win32_callbacks.json');
  // Win32 callbacks are manually created

  print('Generating FFI function bindings...');
  generateFunctions(functionsToGenerate);

  print('Generating COM interfaces and tests...');
  final comTypesToGenerate = loadMap('com_types.json');
  saveMap(comTypesToGenerate, 'com_types.json');
  generateComApis(comTypesToGenerate);

  print('Generating Windows Runtime interfaces...');
  final winrtTypesToGenerate = loadMap('winrt_types.json');
  saveMap(winrtTypesToGenerate, 'winrt_types.json');
  generateWinRTApis(winrtTypesToGenerate);

  print('Generating Windows Runtime enumerations...');
  final winrtEnumsToGenerate = loadMap('winrt_enums.json');
  saveMap(winrtEnumsToGenerate, 'winrt_enums.json');
  generateWinRTEnumerations(winrtEnumsToGenerate);

  print('Generating Windows Runtime structs...');
  final winrtStructsToGenerate = loadMap('winrt_structs.json');
  saveMap(winrtStructsToGenerate, 'winrt_structs.json');
  generateWinRTStructs(winrtStructsToGenerate);
}
