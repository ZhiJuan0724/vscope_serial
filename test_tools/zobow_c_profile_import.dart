import 'dart:convert';
import 'dart:io';

import 'package:vscope_serial/data/models/zobow_config_profile.dart';
import 'package:vscope_serial/services/zobow_c_profile_importer.dart';

Future<void> main(List<String> args) async {
  final arguments = args.toList();
  final ignoreComments = arguments.remove('--ignore-comments');
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run test_tools/zobow_c_profile_import.dart [--ignore-comments] <file.c>',
    );
    exitCode = 64;
    return;
  }

  final file = File(arguments.single);
  if (!file.existsSync()) {
    stderr.writeln('File not found: ${arguments.single}');
    exitCode = 66;
    return;
  }

  final result = await ZobowCProfileImporter.parseFile(
    file.path,
    useComments: !ignoreComments,
  );
  if (result.presets.isEmpty) {
    stderr.writeln('No importable switch presets found in ChxValueTable.');
    exitCode = 1;
    return;
  }

  final profile = ZobowConfigProfile(
    id: _fileBaseName(file.path),
    name: _fileBaseName(file.path),
    presets: result.presets,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(profile.toJson()));
}

String _fileBaseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final name = normalized.substring(normalized.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}
