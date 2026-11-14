import 'package:codegen_e2e/routes.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('the generated locations encode path and query parameters', () {
    expect(const HomeRoute().location, '/');
    expect(const FamilyRoute(fid: 'f1', tab: 2).location, '/family/f1?tab=2');
    expect(const FamilyRoute(fid: 'f1').location, '/family/f1');
  });

  testWidgets('the generated routes parse a location back into its route', (
    tester,
  ) async {
    final router = GoRouter(routes: $appRoutes);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      WidgetsApp.router(
        routerConfig: router,
        color: const Color(0xFF000000),
      ),
    );
    expect(find.text('home'), findsOneWidget);

    router.go(const FamilyRoute(fid: 'f7', tab: 3).location);
    await tester.pumpAndSettle();
    expect(find.text('family f7, tab 3'), findsOneWidget);
  });
}
