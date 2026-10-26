/// BugCapsule for Flutter: capture the context around a failure into a
/// portable `.bugcapsule` capsule, and replay it locally with the `bugcapsule`
/// CLI (`dart run bug_capsule:bugcapsule`).
///
/// One import gives the runtime and every integration; list the ones the app
/// uses in `BugCapsule.init(integrations: [...])`.
library;

export 'src/runtime/runtime.dart';

export 'src/integrations/bloc.dart';
export 'src/integrations/dio.dart';
export 'src/integrations/getx.dart';
export 'src/integrations/go_router.dart';
export 'src/integrations/http.dart';
export 'src/integrations/mobx.dart';
export 'src/integrations/platform_channels.dart';
export 'src/integrations/provider.dart';
export 'src/integrations/riverpod.dart';
export 'src/integrations/storage.dart';
export 'src/integrations/web_socket.dart';
