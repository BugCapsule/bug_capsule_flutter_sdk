# Flutter patch lab

This test application exercises the signed patch runtime and delivery transport.
It is not a customer production application.

Its immutable runtime scope can be selected at build time:

```sh
flutter build ios --simulator --debug \
  --dart-define=BCPATCH_APPLICATION_ID=com.bugcapsule.qualification \
  --dart-define=BCPATCH_ENVIRONMENT=qa \
  --dart-define=BCPATCH_BASE_BUILD=qualification-host-20261101
```

Run from this example directory after resolving workspace dependencies and
installing the reviewed runtime XCFramework required by the patch plugin.
Defaults remain `dev.bugcapsule.patchlab.flutter`, `staging`, and
`flutter-demo-1`. These define the patch protocol identity; they do not change
the operating system bundle identifier. Distribution profile remains development.

The existing private `Documents/patch-config.json` accepts `projectId`,
`baseUrl`, `deliveryToken`, and `trustRoots` (a nonempty array of public
`bcpk.v1.*` pins). The legacy single `trustRoot` remains supported when
`trustRoots` is absent; malformed explicit lists are refused.
Use a real scoped delivery credential matching the compiled application and
environment. Never commit that file or a token. An absent config uses the
existing local file inbox. The runtime store is kept in application support.

After staging, terminate and relaunch the same installed app to activate.
Check the written result and exact runtime identity, then publish a signed
rollback through the normal operator workflow and relaunch again. Preserve
the same installation and store across both transitions. Do not interpret
publication or a successful HTTP check as confirmed activation. Simulator
execution is not physical device or public distribution qualification.
