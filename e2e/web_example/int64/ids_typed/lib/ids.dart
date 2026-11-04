import 'dart:typed_data';

/// 64-bit identifiers, held in an [Int64List]: only dart2wasm (and the VM) can
/// hold one.
typedef Ids = Int64List;

/// What [Ids] is, for the app to show.
const idsType = 'Int64List';

/// The largest signed 64-bit integer. dart2js cannot represent it ("can't be
/// represented exactly in JavaScript") and refuses to compile the literal.
const maxId = 0x7FFFFFFFFFFFFFFF;

/// Two identifiers, the first of them [maxId].
Ids makeIds() => Int64List.fromList([maxId, 1 << 40]);
