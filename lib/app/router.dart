import 'package:go_router/go_router.dart';

import '../app/session.dart';
import '../app/shell.dart';
import '../screens/articles_screen.dart';
import '../screens/data_screen.dart';
import '../screens/library_screen.dart';
import '../screens/portal_screen.dart';
import '../screens/review_screen.dart';

GoRouter buildRouter(AppSession session) => GoRouter(
      initialLocation: '/',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppWebShell(
            session: session,
            location: state.uri.path,
            child: child,
          ),
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => PortalScreen(session: session),
            ),
            GoRoute(
              path: '/library',
              builder: (context, state) => LibraryScreen(session: session),
            ),
            GoRoute(
              path: '/articles',
              builder: (context, state) => ArticlesScreen(session: session),
            ),
            GoRoute(
              path: '/articles/:id',
              builder: (context, state) => ArticleReaderScreen(
                session: session,
                articleId: state.pathParameters['id'] ?? '',
              ),
            ),
            GoRoute(
              path: '/review',
              builder: (context, state) => ReviewScreen(session: session),
            ),
            GoRoute(path: '/data', builder: (context, state) => DataScreen(session: session)),
          ],
        ),
      ],
    );
