import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:bug_capsule/bug_capsule.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shop.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final home = context.watch<HomeCubit>().state;
    return Scaffold(
      appBar: AppBar(title: const Text('BugCapsule Shop')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            home.profileName == null
                ? 'Welcome'
                : 'Welcome back, ${home.profileName} (${home.tier})',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (home.banner != null) Text(home.banner!),
          for (final p in home.picks) ListTile(dense: true, title: Text(p)),
          if (home.loading) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('home.refresh'),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh picks'),
            onPressed: BugCapsule.action('home.refresh', () => context.read<HomeCubit>().refresh()),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('home.cart'),
            icon: const Icon(Icons.shopping_cart),
            label: const Text('Open cart'),
            onPressed: BugCapsule.action('home.cart', () => context.push('/cart')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('home.orders'),
            icon: const Icon(Icons.receipt_long),
            label: const Text('My orders'),
            onPressed: BugCapsule.action('home.orders', () => context.push('/orders')),
          ),
          const SizedBox(height: 32),
          const Divider(),
          Text('Bug lab', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text(
            'Each flow fails only sometimes: it depends on server data, response '
            'timing, or what an older app version left on the device.',
          ),
          TextButton(
            key: const Key('lab.legacy'),
            onPressed: BugCapsule.action('lab.legacy', () async {
              final prefs = await SharedPreferences.getInstance();
              // What v0.9 used to write. Restart the app, then open the cart.
              await prefs.setString(CartBloc.cacheKey, '["mug","tee"]');
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Wrote v0.9 cart cache. Restart the app, then open the cart.')));
              }
            }),
            child: const Text('Simulate upgrade from v0.9'),
          ),
          TextButton(
            key: const Key('lab.clear'),
            onPressed: BugCapsule.action('lab.clear', () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove(CartBloc.cacheKey);
            }),
            child: const Text('Clear local cart cache'),
          ),
        ],
      ),
    );
  }
}

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _coupon = TextEditingController();

  @override
  void initState() {
    super.initState();
    BugCapsule.trackText('cart.coupon', _coupon);
  }

  @override
  void dispose() {
    BugCapsule.untrackText('cart.coupon', _coupon);
    _coupon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartBloc>().state;
    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: switch (cart.status) {
        CartStatus.loading => const Center(child: CircularProgressIndicator()),
        CartStatus.paid => Center(child: Text('Paid! Order ${cart.orderId}')),
        _ => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final item in cart.items)
                ListTile(
                  title: Text(item.name),
                  subtitle: Text('Qty ${item.qty}'),
                  trailing: Text(item.price == null ? 'unavailable' : '\$${item.price!.toStringAsFixed(2)}'),
                ),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('cart.coupon'),
                      controller: _coupon,
                      decoration: const InputDecoration(labelText: 'Coupon (try SAVE10 or SAVE100)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('cart.applyCoupon'),
                    onPressed: BugCapsule.action('cart.applyCoupon',
                        () => context.read<CartBloc>().add(CouponApplied(_coupon.text))),
                    child: const Text('Apply'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Subtotal \$${cart.subtotal.toStringAsFixed(2)}'),
              if (cart.discount > 0) Text('Discount -\$${cart.discount.toStringAsFixed(2)}'),
              Text('Total \$${cart.total.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('cart.checkout'),
                onPressed: cart.status == CartStatus.checkingOut
                    ? null
                    : BugCapsule.action('cart.checkout',
                        () => context.read<CartBloc>().add(const CheckoutPressed())),
                child: Text(cart.status == CartStatus.checkingOut ? 'Paying…' : 'Checkout'),
              ),
            ],
          ),
      },
    );
  }
}

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersCubit>().state;
    return Scaffold(
      appBar: AppBar(title: const Text('My orders')),
      body: orders.loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                for (final o in orders.orders)
                  ListTile(title: Text('${o['id']}'), subtitle: Text('${o['status']}'), trailing: Text('\$${o['total']}')),
              ],
            ),
    );
  }
}
