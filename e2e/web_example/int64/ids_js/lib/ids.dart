/// The JavaScript variant of `ids_typed`: the same API over a plain list,
/// because dart2js (and DDC) cannot hold a 64-bit integer.
typedef Ids = List<int>;

/// What [Ids] is, for the app to show.
const idsType = 'List<int>';

/// The largest integer JavaScript represents exactly: 2^53 - 1.
const maxId = 9007199254740991;

/// Two identifiers, the first of them [maxId].
Ids makeIds() => <int>[maxId, 1 << 40];
