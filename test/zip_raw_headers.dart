/// Raw ZIP local/central header fields (DOS time/date + `UT` extra), not
/// [ZipDecoder] projections.
library;

const _sigLocal = 0x04034b50;
const _sigCentral = 0x02014b50;
const _sigEocd = 0x06054b50;
const _utExtraId = 0x5455;

/// One entry's encoded MS-DOS fields and optional Unix timestamp (`UT` extra).
typedef ZipRawEntryMeta = ({
  String name,
  int dosTime,
  int dosDate,
  int? utSeconds,
  bool fromCentral,
});

int? _readUtSeconds(List<int> extra) {
  var i = 0;
  while (i + 4 <= extra.length) {
    final id = extra[i] | (extra[i + 1] << 8);
    final size = extra[i + 2] | (extra[i + 3] << 8);
    if (i + 4 + size > extra.length) break;
    final data = extra.sublist(i + 4, i + 4 + size);
    if (id == _utExtraId && data.length >= 5 && data[0] == 1) {
      return data[1] |
          (data[2] << 8) |
          (data[3] << 16) |
          (data[4] << 24);
    }
    i += 4 + size;
  }
  return null;
}

int _u32(List<int> bytes, int off) =>
    bytes[off] |
    (bytes[off + 1] << 8) |
    (bytes[off + 2] << 16) |
    (bytes[off + 3] << 24);

ZipRawEntryMeta? _readCentralAt(List<int> bytes, int off) {
  if (off + 46 > bytes.length || _u32(bytes, off) != _sigCentral) {
    return null;
  }
  final dosTime = bytes[off + 12] | (bytes[off + 13] << 8);
  final dosDate = bytes[off + 14] | (bytes[off + 15] << 8);
  final nameLen = bytes[off + 28] | (bytes[off + 29] << 8);
  final extraLen = bytes[off + 30] | (bytes[off + 31] << 8);
  final commentLen = bytes[off + 32] | (bytes[off + 33] << 8);
  final nameStart = off + 46;
  final total = nameStart + nameLen + extraLen + commentLen;
  if (total > bytes.length || nameLen == 0) return null;
  final name = String.fromCharCodes(
    bytes.sublist(nameStart, nameStart + nameLen),
  );
  final extra = bytes.sublist(
    nameStart + nameLen,
    nameStart + nameLen + extraLen,
  );
  return (
    name: name,
    dosTime: dosTime,
    dosDate: dosDate,
    utSeconds: _readUtSeconds(extra),
    fromCentral: true,
  );
}

int? _centralDirectoryOffset(List<int> bytes) {
  const minEocd = 22;
  final start = bytes.length >= minEocd ? bytes.length - minEocd : 0;
  for (var off = start; off >= 0; off--) {
    if (_u32(bytes, off) != _sigEocd) continue;
    final cdOffset = _u32(bytes, off + 16);
    if (cdOffset < 0 || cdOffset >= bytes.length) continue;
    if (_u32(bytes, cdOffset) == _sigCentral) return cdOffset;
  }
  return null;
}

List<ZipRawEntryMeta> zipRawLocalEntryMetadata(List<int> bytes) {
  final out = <ZipRawEntryMeta>[];
  for (var off = 0; off + 30 <= bytes.length; off++) {
    if (_u32(bytes, off) != _sigLocal) continue;
    final dosTime = bytes[off + 10] | (bytes[off + 11] << 8);
    final dosDate = bytes[off + 12] | (bytes[off + 13] << 8);
    final nameLen = bytes[off + 26] | (bytes[off + 27] << 8);
    final extraLen = bytes[off + 28] | (bytes[off + 29] << 8);
    final nameStart = off + 30;
    if (nameStart + nameLen + extraLen > bytes.length || nameLen == 0) {
      continue;
    }
    final name = String.fromCharCodes(
      bytes.sublist(nameStart, nameStart + nameLen),
    );
    out.add((
      name: name,
      dosTime: dosTime,
      dosDate: dosDate,
      utSeconds: null, // archive 4.6+ writes `UT` only in central directory
      fromCentral: false,
    ));
  }
  return out;
}

List<ZipRawEntryMeta> zipRawCentralEntryMetadata(List<int> bytes) {
  final cd = _centralDirectoryOffset(bytes);
  if (cd == null) return [];
  final out = <ZipRawEntryMeta>[];
  var off = cd;
  while (off + 46 <= bytes.length && _u32(bytes, off) == _sigCentral) {
    final meta = _readCentralAt(bytes, off);
    if (meta == null) break;
    out.add(meta);
    final nameLen = bytes[off + 28] | (bytes[off + 29] << 8);
    final extraLen = bytes[off + 30] | (bytes[off + 31] << 8);
    final commentLen = bytes[off + 32] | (bytes[off + 33] << 8);
    off += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

/// Collects every local and central file header's DOS + `UT` fields.
List<ZipRawEntryMeta> allZipRawEntryMetadata(List<int> bytes) => [
      ...zipRawLocalEntryMetadata(bytes),
      ...zipRawCentralEntryMetadata(bytes),
    ];
