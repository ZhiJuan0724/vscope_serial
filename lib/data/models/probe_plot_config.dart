import 'dart:typed_data';

enum ProbePlotMode {
  hss('HSS'),
  rtt('RTT');

  const ProbePlotMode(this.label);
  final String label;
}

enum ProbeScalarType {
  boolean('bool', 1),
  int8('int8', 1),
  int16('int16', 2),
  int32('int32', 4),
  int64('int64', 8),
  uint8('uint8', 1),
  uint16('uint16', 2),
  uint32('uint32', 4),
  uint64('uint64', 8),
  float32('float32', 4),
  float64('float64', 8);

  const ProbeScalarType(this.label, this.byteSize);
  final String label;
  final int byteSize;
}

class ProbeSampleVariable {
  const ProbeSampleVariable({
    required this.name,
    required this.address,
    required this.type,
  });

  final String name;
  final int address;
  final ProbeScalarType type;
}

class ProbeSampleChunk {
  const ProbeSampleChunk({required this.monotonicUs, required this.values});

  final int monotonicUs;
  final Float64List values;
}

class RttChannelInfo {
  const RttChannelInfo({
    required this.index,
    required this.name,
    required this.size,
    required this.flags,
  });

  final int index;
  final String name;
  final int size;
  final int flags;
}

class ProbeSymbolInfo {
  const ProbeSymbolInfo({
    required this.name,
    required this.address,
    required this.size,
    this.type,
    this.source = 'symbol',
  });

  final String name;
  final int address;
  final int size;
  final ProbeScalarType? type;
  final String source;
}
