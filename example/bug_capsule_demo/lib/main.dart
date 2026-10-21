import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:bug_capsule/bug_capsule.dart';

import 'fake_server.dart';
import 'screens.dart';
import 'shop.dart';

const _backendUrl = String.fromEnvironment('BUGCAPSULE_BACKEND_URL');
const _ingestKey = String.fromEnvironment('BUGCAPSULE_INGEST_KEY');

final bugCapsuleDio = BugCapsuleDio(rules: [
  // Checkout bodies carry a timestamp and nonce that differ on every run.
  EndpointRule('POST', '/api/checkout', ignoreBodyFields: {'timestamp', 'nonce'}),
]);
final bugCapsuleRouter = BugCapsuleGoRouter();

void main() => BugCapsule.init(
      config: BugCapsuleConfig(
        appId: 'com.bugcapsule.bug_capsule_demo',
        appName: 'BugCapsule Shop',
        appVersion: '1.0.0',
        appBuild: '1',
        mode: CaptureMode.qa,
        backend: _backendUrl.isEmpty || _ingestKey.isEmpty
            ? null
            : const BugCapsuleBackendConfig(url: _backendUrl, ingestKey: _ingestKey),
      ),
      integrations: [
        BugCapsuleBloc(states: [
          BugCapsuleState<CartBloc, CartState>(toJson: (s) => s.toJson(), fromJson: CartState.fromJson),
          BugCapsuleState<HomeCubit, HomeState>(toJson: (s) => s.toJson(), fromJson: HomeState.fromJson),
        ]),
        bugCapsuleDio,
        bugCapsuleRouter,
        BugCapsuleSharedPreferences(),
      ],
      appRunner: () => runApp(const ShopApp()),
    );

class ShopApp extends StatefulWidget {
  const ShopApp({super.key});

  @override
  State<ShopApp> createState() => _ShopAppState();
}

class _ShopAppState extends State<ShopApp> {
  late final ShopApi _api;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final dio = Dio(BaseOptions(baseUrl: 'https://shop.bugcapsule.com'))
      ..httpClientAdapter = FakeShopServer();
    bugCapsuleDio.attach(dio);
    _api = ShopApi(dio);
    _router = GoRouter(
      initialLocation: bugCapsuleRouter.initialLocation('/'),
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/cart',
          builder: (_, _) => BlocProvider(
            create: (_) => CartBloc(_api)..add(const CartLoaded()),
            child: const CartScreen(),
          ),
        ),
        GoRoute(
          path: '/orders',
          builder: (_, _) => BlocProvider(
            create: (_) => OrdersCubit(_api)..load(),
            child: const OrdersScreen(),
          ),
        ),
      ],
    );
    bugCapsuleRouter.attach(_router);
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => HomeCubit(_api),
      child: MaterialApp.router(
        title: 'BugCapsule Shop',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1D4ED8)),
        routerConfig: _router,
        builder: (context, child) => BugCapsuleOverlay(child: child!),
      ),
    );
  }
}
