/// Routes declared with `@TypedGoRoute`, whose `$appRoutes`, mixins and
/// locations live in a generated `part` (lib/routes.g.dart, written by
/// go_router_builder through `go_router_codegen`).
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

part 'routes.g.dart';

/// The root route, with [FamilyRoute] below it.
@TypedGoRoute<HomeRoute>(
  path: '/',
  routes: <TypedGoRoute<GoRouteData>>[
    TypedGoRoute<FamilyRoute>(path: 'family/:fid'),
  ],
)
class HomeRoute extends GoRouteData with $HomeRoute {
  /// The root route.
  const HomeRoute();

  @override
  Widget build(BuildContext context, GoRouterState state) => const Text('home');
}

/// A route with a path parameter, [fid], and a query parameter, [tab].
class FamilyRoute extends GoRouteData with $FamilyRoute {
  /// The route of family [fid], showing [tab].
  const FamilyRoute({required this.fid, this.tab = 0});

  /// The family's id, from the path.
  final String fid;

  /// The tab shown, from the query.
  final int tab;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      Text('family $fid, tab $tab');
}
