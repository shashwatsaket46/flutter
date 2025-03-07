// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../artifacts.dart';
import '../base/analyze_size.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/project_migrator.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../cache.dart';
import '../cmake.dart';
import '../cmake_project.dart';
import '../convert.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../migrations/cmake_custom_command_migration.dart';
import 'install_manifest.dart';
import 'visual_studio.dart';

// From https://cmake.org/cmake/help/v3.14/manual/cmake-generators.7.html#visual-studio-generators
// This may need to become a getter on VisualStudio in the future to support
// future major versions of Visual Studio.
const String _cmakeVisualStudioGeneratorIdentifier = 'Visual Studio 16 2019';

/// Update the string when non-backwards compatible changes are made to the UWP template.
const int kCurrentUwpTemplateVersion = 0;

/// Builds the Windows project using msbuild.
Future<void> buildWindows(WindowsProject windowsProject, BuildInfo buildInfo, {
  String? target,
  VisualStudio? visualStudioOverride,
  SizeAnalyzer? sizeAnalyzer,
}) async {
  if (!windowsProject.cmakeFile.existsSync()) {
    throwToolExit(
      'No Windows desktop project configured. See '
      'https://flutter.dev/desktop#add-desktop-support-to-an-existing-flutter-app '
      'to learn about adding Windows support to a project.');
  }

  final List<ProjectMigrator> migrators = <ProjectMigrator>[
    CmakeCustomCommandMigration(windowsProject, globals.logger),
  ];

  final ProjectMigration migration = ProjectMigration(migrators);
  if (!migration.run()) {
    throwToolExit('Unable to migrate project files');
  }

  // Ensure that necessary ephemeral files are generated and up to date.
  _writeGeneratedFlutterConfig(windowsProject, buildInfo, target);
  createPluginSymlinks(windowsProject.parent);

  final VisualStudio visualStudio = visualStudioOverride ?? VisualStudio(
    fileSystem: globals.fs,
    platform: globals.platform,
    logger: globals.logger,
    processManager: globals.processManager,
  );
  final String? cmakePath = visualStudio.cmakePath;
  if (cmakePath == null) {
    throwToolExit('Unable to find suitable Visual Studio toolchain. '
        'Please run `flutter doctor` for more details.');
  }

  final String buildModeName = getNameForBuildMode(buildInfo.mode);
  final Directory buildDirectory = globals.fs.directory(getWindowsBuildDirectory());
  final Status status = globals.logger.startProgress(
    'Building Windows application...',
  );
  try {
    await _runCmakeGeneration(cmakePath, buildDirectory, windowsProject.cmakeFile.parent);
    await _runBuild(cmakePath, buildDirectory, buildModeName);
  } finally {
    status.cancel();
  }
  if (buildInfo.codeSizeDirectory != null && sizeAnalyzer != null) {
    final String arch = getNameForTargetPlatform(TargetPlatform.windows_x64);
    final File codeSizeFile = globals.fs.directory(buildInfo.codeSizeDirectory)
      .childFile('snapshot.$arch.json');
    final File precompilerTrace = globals.fs.directory(buildInfo.codeSizeDirectory)
      .childFile('trace.$arch.json');
    final Map<String, Object?> output = await sizeAnalyzer.analyzeAotSnapshot(
      aotSnapshot: codeSizeFile,
      // This analysis is only supported for release builds.
      outputDirectory: globals.fs.directory(
        globals.fs.path.join(getWindowsBuildDirectory(), 'runner', 'Release'),
      ),
      precompilerTrace: precompilerTrace,
      type: 'windows',
    );
    final File outputFile = globals.fsUtils.getUniqueFile(
      globals.fs
        .directory(globals.fsUtils.homeDirPath)
        .childDirectory('.flutter-devtools'), 'windows-code-size-analysis', 'json',
    )..writeAsStringSync(jsonEncode(output));
    // This message is used as a sentinel in analyze_apk_size_test.dart
    globals.printStatus(
      'A summary of your Windows bundle analysis can be found at: ${outputFile.path}',
    );

    // DevTools expects a file path relative to the .flutter-devtools/ dir.
    final String relativeAppSizePath = outputFile.path.split('.flutter-devtools/').last.trim();
    globals.printStatus(
      '\nTo analyze your app size in Dart DevTools, run the following command:\n'
      'flutter pub global activate devtools; flutter pub global run devtools '
      '--appSizeBase=$relativeAppSizePath'
    );
  }
}

/// Build the Windows UWP project.
///
/// Note that this feature is currently unfinished.
Future<void> buildWindowsUwp(WindowsUwpProject windowsProject, BuildInfo buildInfo, {
  String? target,
  VisualStudio? visualStudioOverride,
}) async {
  final Directory buildDirectory = globals.fs.directory(getWindowsBuildUwpDirectory());
  if (!windowsProject.existsSync()) {
    throwToolExit(
      'No Windows UWP desktop project configured. See '
      'https://flutter.dev/desktop#add-desktop-support-to-an-existing-flutter-app '
      'to learn about adding Windows support to a project.',
    );
  }
  if (windowsProject.projectVersion != kCurrentUwpTemplateVersion) {
    throwToolExit(
      'The Windows UWP project template and build process has changed. In order to build '
      'you must delete the winuwp directory and re-create the project.',
    );
  }
   // Ensure that necessary ephemeral files are generated and up to date.
  _writeGeneratedFlutterConfig(windowsProject, buildInfo, target);
  createPluginSymlinks(windowsProject.parent);
  await createManifest(
    buildDirectory: buildDirectory,
    logger: globals.logger,
    platform: globals.platform,
    project: windowsProject,
    buildInfo: buildInfo,
    fileSystem: globals.fs,
  );

  final VisualStudio visualStudio = visualStudioOverride ?? VisualStudio(
    fileSystem: globals.fs,
    platform: globals.platform,
    logger: globals.logger,
    processManager: globals.processManager,
  );
  final String? cmakePath = visualStudio.cmakePath;
  if (cmakePath == null) {
    throwToolExit('Unable to find suitable Visual Studio toolchain. '
        'Please run `flutter doctor` for more details.');
  }

  final String buildModeName = getNameForBuildMode(buildInfo.mode);
  final Status status = globals.logger.startProgress(
    'Building Windows UWP application...',
  );
  try {
    // The Cmake re-entrant build does not work for UWP, so the flutter build is
    // run in advance.
    await _runFlutterBuild(buildDirectory, buildInfo, target);
    await _runCmakeGeneration(cmakePath, buildDirectory, windowsProject.cmakeFile.parent);
    await _runBuild(cmakePath, buildDirectory, buildModeName, install: false);
  } finally {
    status.cancel();
  }
}

const Map<BuildMode, String> _targets = <BuildMode, String>{
  BuildMode.debug: 'debug_bundle_windows_assets_uwp',
  BuildMode.profile: 'profile_bundle_windows_assets_uwp',
  BuildMode.release: 'release_bundle_windows_assets_uwp',
};

Future<void> _runFlutterBuild(Directory buildDirectory, BuildInfo buildInfo, String? targetFile) async {
  await buildDirectory.create(recursive: true);
  int result;
  String? flutterEngine;
  String? localEngine;
  final Artifacts artifacts = globals.artifacts!;
  if (artifacts is LocalEngineArtifacts) {
    final String engineOutPath = artifacts.engineOutPath;
    flutterEngine = globals.fs.path.dirname(globals.fs.path.dirname(engineOutPath));
    localEngine = globals.fs.path.basename(engineOutPath);
  }
  try {
    final String? buildMode = _targets[buildInfo.mode];
    result = await globals.processUtils.stream(
      <String>[
        globals.fs.path.join(Cache.flutterRoot!, 'bin', 'flutter'),
        if (globals.logger.isVerbose)
          '--verbose',
        if (flutterEngine != null) '--local-engine-src-path=$flutterEngine',
        if (localEngine != null) '--local-engine=$localEngine',
        'assemble',
        '--no-version-check',
        '--output=build',
        '-dTargetPlatform=windows-uwp-x64',
        '-dTrackWidgetCreation=${buildInfo.trackWidgetCreation}',
        '-dBuildMode=${getNameForBuildMode(buildInfo.mode)}',
        '-dTargetFile=$targetFile',
        '-dTreeShakeIcons="${buildInfo.treeShakeIcons}"',
        '-dDartObfuscation=${buildInfo.dartObfuscation}',
        if (buildInfo.bundleSkSLPath != null)
          '-dBundleSkSLPath=${buildInfo.bundleSkSLPath}',
        if (buildInfo.codeSizeDirectory != null)
          '-dCodeSizeDirectory=${buildInfo.codeSizeDirectory}',
        if (buildInfo.splitDebugInfoPath != null)
          '-dSplitDebugInfo=${buildInfo.splitDebugInfoPath}',
        if (buildInfo.dartDefines != null && buildInfo.dartDefines.isNotEmpty)
          '--DartDefines=${encodeDartDefines(buildInfo.dartDefines)}',
        if (buildInfo.extraGenSnapshotOptions != null && buildInfo.extraGenSnapshotOptions.isNotEmpty)
          '--ExtraGenSnapshotOptions=${buildInfo.extraGenSnapshotOptions}',
        if (buildInfo.extraFrontEndOptions != null && buildInfo.extraFrontEndOptions.isNotEmpty)
          '--ExtraFrontEndOptions=${buildInfo.extraFrontEndOptions}',
        if (buildMode != null)
          buildMode,
      ],
      trace: true,
    );
  } on ArgumentError {
    throwToolExit("cmake not found. Run 'flutter doctor' for more information.");
  }
  if (result != 0) {
    throwToolExit('Unable to generate build files');
  }
}

Future<void> _runCmakeGeneration(String cmakePath, Directory buildDir, Directory sourceDir) async {
  final Stopwatch sw = Stopwatch()..start();

  await buildDir.create(recursive: true);
  int result;
  try {
    result = await globals.processUtils.stream(
      <String>[
        cmakePath,
        '-S',
        sourceDir.path,
        '-B',
        buildDir.path,
        '-G',
        _cmakeVisualStudioGeneratorIdentifier,
      ],
      trace: true,
    );
  } on ArgumentError {
    throwToolExit("cmake not found. Run 'flutter doctor' for more information.");
  }
  if (result != 0) {
    throwToolExit('Unable to generate build files');
  }
  globals.flutterUsage.sendTiming('build', 'windows-cmake-generation', Duration(milliseconds: sw.elapsedMilliseconds));
}

Future<void> _runBuild(
  String cmakePath,
  Directory buildDir,
  String buildModeName,
  { bool install = true }
) async {
  final Stopwatch sw = Stopwatch()..start();

  // MSBuild sends all output to stdout, including build errors. This surfaces
  // known error patterns.
  final RegExp errorMatcher = RegExp(r':\s*(?:warning|(?:fatal )?error).*?:');

  int result;
  try {
    result = await globals.processUtils.stream(
      <String>[
        cmakePath,
        '--build',
        buildDir.path,
        '--config',
        sentenceCase(buildModeName),
        if (install)
          ...<String>['--target', 'INSTALL'],
        if (globals.logger.isVerbose)
          '--verbose'
      ],
      environment: <String, String>{
        if (globals.logger.isVerbose)
          'VERBOSE_SCRIPT_LOGGING': 'true'
      },
      trace: true,
      stdoutErrorMatcher: errorMatcher,
    );
  } on ArgumentError {
    throwToolExit("cmake not found. Run 'flutter doctor' for more information.");
  }
  if (result != 0) {
    throwToolExit('Build process failed.');
  }
  globals.flutterUsage.sendTiming('build', 'windows-cmake-build', Duration(milliseconds: sw.elapsedMilliseconds));
}

/// Writes the generated CMake file with the configuration for the given build.
void _writeGeneratedFlutterConfig(
  WindowsProject windowsProject,
  BuildInfo buildInfo,
  String? target,
) {
  final Map<String, String> environment = <String, String>{
    'FLUTTER_ROOT': Cache.flutterRoot!,
    'FLUTTER_EPHEMERAL_DIR': windowsProject.ephemeralDirectory.path,
    'PROJECT_DIR': windowsProject.parent.directory.path,
    if (target != null)
      'FLUTTER_TARGET': target,
    ...buildInfo.toEnvironmentConfig(),
  };
  final Artifacts artifacts = globals.artifacts!;
  if (artifacts is LocalEngineArtifacts) {
    final String engineOutPath = artifacts.engineOutPath;
    environment['FLUTTER_ENGINE'] = globals.fs.path.dirname(globals.fs.path.dirname(engineOutPath));
    environment['LOCAL_ENGINE'] = globals.fs.path.basename(engineOutPath);
  }
  writeGeneratedCmakeConfig(Cache.flutterRoot!, windowsProject, environment);
}
