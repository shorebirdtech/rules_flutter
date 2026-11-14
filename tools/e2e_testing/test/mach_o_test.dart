import 'package:rules_flutter_e2e_testing/mach_o.dart';
import 'package:test/test.dart';

void main() {
  group('SymbolCounts.parse', () {
    test('counts local, stab and external entries apart', () {
      final counts = SymbolCounts.parse('''
000000000011b024 t MyApp.build
000000000011b024 - 01 0000   FUN MyApp.build
0000000000001000 T _kDartVmSnapshotData
0000000000002000 b _zerofill
0000000000003000 S _kDartIsolateSnapshotInstructions
                 U dyld_stub_binder
''');
      expect(counts.local, 2);
      expect(counts.stabs, 1);
      expect(counts.external, 3);
    });

    test('an empty listing has no symbols', () {
      final counts = SymbolCounts.parse('');
      expect(counts.local + counts.stabs + counts.external, 0);
    });
  });
}
