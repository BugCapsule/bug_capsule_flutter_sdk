import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:repro_bloc/repro_bloc.dart';
import 'package:repro_dio/repro_dio.dart';
import 'package:repro_flutter/repro_flutter.dart';
import 'package:repro_go_router/repro_go_router.dart';
import 'package:repro_storage/repro_storage.dart';

import 'fake_server.dart';
import 'screens.dart';
import 'shop.dart';

const _backendUrl = String.fromEnvironment('REPRO_BACKEND_URL');
const _ingestKey = String.fromEnvironment('REPRO_INGEST_KEY');

final reproDio = ReproDio(rules: [
  // Checkout bodies carry a timestamp and nonce that differ on every run.
  EndpointRule('POST', '/api/checkout', ignoreBodyFields: {'timestamp', 'nonce'}),
]);
final reproRouter = ReproGoRouter();

void main() => Repro.init(
      config: ReproConfig(
        appId: 'dev.repro.repro_demo',
        appName: 'Repro Shop',
        appVersion: '1.0.0',
        appBuild: '1',
        mode: CaptureMode.qa,
        backend: _backendUrl.isEmpty || _ingestKey.isEmpty
            ? null
            : const ReproBackendConfig(url: _backendUrl, ingestKey: _ingestKey),
      ),
      integrations: [
        ReproBloc(states: [
          ReproState<CartBloc, CartState>(toJson: (s) => s.toJson(), fromJson: CartState.fromJson),
          ReproState<HomeCubit, HomeState>(toJson: (s) => s.toJson(), fromJson: HomeState.fromJson),
        ]),
        reproDio,
        reproRouter,
        ReproSharedPreferences(),
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
    final dio = Dio(BaseOptions(baseUrl: 'https://shop.repro.dev'))
      ..httpClientAdapter = FakeShopServer();
    reproDio.attach(dio);
    _api = ShopApi(dio);
    _router = GoRouter(
      initialLocation: reproRouter.initialLocation('/'),
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
    reproRouter.attach(_router);
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => HomeCubit(_api),
      child: MaterialApp.router(
        title: 'Repro Shop',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1D4ED8)),
        routerConfig: _router,
        builder: (context, child) => ReproOverlay(child: child!),
      ),
    );
  }
}
