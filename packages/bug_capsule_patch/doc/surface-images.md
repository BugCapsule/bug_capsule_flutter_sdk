# Surface image fallback

List each image ID in the surface registration's `assets` and include `image` in
`components`. Pass shipped image providers through the existing `images` map:

```dart
PatchSurfaceView(
  patch: patch,
  id: 'checkout.summary',
  actions: {'checkout.pay': pay},
  images: const {'brand.logo': AssetImage('assets/brand_logo.png')},
  bundled: const BundledCheckoutSummary(),
)
```

Image nodes use the registered `asset` ID and expose their required `label` as
an image semantic label. If any image provider is missing, even inside a nested
list, the whole bundled surface renders. Surfaces with no image nodes continue
to work with the default empty map. Host image providers control loading and
decoding; the renderer does not decode compressed patch assets.

Widget regressions use the real host runtime when `BCPATCH_HOST_LIB` is set,
with signed layout fixtures embedded in the test. They cover missing nested
images, supplied images and labels, and surfaces that need no images.
