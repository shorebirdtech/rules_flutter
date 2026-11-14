import 'package:rules_flutter_e2e_testing/bytes.dart';
import 'package:test/test.dart';

void main() {
  test('containsBytes finds a run anywhere, and only a whole run', () {
    expect(containsBytes([1, 2, 3, 4], [2, 3]), isTrue);
    expect(containsBytes([1, 2, 3, 4], [1]), isTrue);
    expect(containsBytes([1, 2, 3, 4], [4]), isTrue);
    expect(containsBytes([1, 2, 3, 4], [3, 2]), isFalse);
    expect(containsBytes([1, 2, 3], [3, 4]), isFalse);
    expect(containsBytes([1, 2], [1, 2, 3]), isFalse);
    expect(containsBytes([1, 2], const []), isTrue);
  });

  test('utf16leBytes puts the low byte first', () {
    expect(utf16leBytes('Ab'), [0x41, 0, 0x62, 0]);
    expect(utf16leBytes('é'), [0xe9, 0]);
  });
}
