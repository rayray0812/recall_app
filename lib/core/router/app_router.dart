import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recall_app/features/auth/screens/forgot_password_screen.dart';
import 'package:recall_app/features/auth/screens/login_screen.dart';
import 'package:recall_app/features/auth/screens/signup_screen.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/core/constants/study_constants.dart';
import 'package:recall_app/features/about/screens/about_screen.dart';
import 'package:recall_app/features/about/screens/legal_document_screen.dart';
import 'package:recall_app/features/admin/screens/admin_management_screen.dart';
import 'package:recall_app/features/classroom/screens/class_detail_screen.dart';
import 'package:recall_app/features/classroom/screens/class_student_detail_screen.dart';
import 'package:recall_app/features/classroom/screens/classes_screen.dart';
import 'package:recall_app/features/onboarding/screens/onboarding_screen.dart';
import 'package:recall_app/features/home/screens/folder_management_screen.dart';
import 'package:recall_app/features/home/screens/search_screen.dart';
import 'package:recall_app/features/share/screens/share_screen.dart';
import 'package:recall_app/features/share/screens/qr_scan_screen.dart';
import 'package:recall_app/features/achievements/screens/achievements_screen.dart';
import 'package:recall_app/features/home/screens/dashboard_screen.dart';
import 'package:recall_app/features/profile/screens/profile_edit_screen.dart';
import 'package:recall_app/features/home/screens/card_editor_screen.dart';
import 'package:recall_app/features/import/screens/web_import_screen.dart';
import 'package:recall_app/features/import/screens/review_import_screen.dart';
import 'package:recall_app/features/import/screens/photo_import_screen.dart';
import 'package:recall_app/features/study/screens/study_mode_picker_screen.dart';
import 'package:recall_app/features/study/screens/flashcard_screen.dart';
import 'package:recall_app/features/study/screens/quiz_screen.dart'
    show QuizScreen, QuizSettings;
import 'package:recall_app/features/study/screens/quiz_complete_screen.dart';
import 'package:recall_app/features/study/screens/learn_mode_screen.dart';
import 'package:recall_app/features/study/screens/matching_game_screen.dart';
import 'package:recall_app/features/study/screens/matching_complete_screen.dart';
import 'package:recall_app/features/study/screens/srs_review_screen.dart';
import 'package:recall_app/features/study/screens/review_summary_screen.dart';
import 'package:recall_app/features/study/screens/revenge_detail_screen.dart';
import 'package:recall_app/features/study/screens/revenge_quiz_screen.dart';
import 'package:recall_app/features/study/screens/speaking_practice_screen.dart';
import 'package:recall_app/features/stats/screens/stats_screen.dart';
import 'package:recall_app/features/community/screens/community_screen.dart';
import 'package:recall_app/features/community/screens/user_profile_screen.dart';
import 'package:recall_app/features/study/screens/custom_study_screen.dart';
import 'package:recall_app/features/study/screens/conversation_setup_screen.dart';
import 'package:recall_app/features/study/screens/conversation_practice_screen.dart';
import 'package:recall_app/features/study/screens/conversation_summary_screen.dart';
import 'package:recall_app/features/study/screens/conversation_history_screen.dart';
import 'package:recall_app/features/study/screens/transcript_detail_screen.dart';
import 'package:recall_app/features/study/models/conversation_transcript.dart';
import 'package:recall_app/models/study_set.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/services/supabase_service.dart';

StudySet? extractStudySetExtra(Object? extra) {
  return extra is StudySet ? extra : null;
}

Map<String, dynamic> extractMapExtra(Object? extra) {
  return extra is Map<String, dynamic> ? extra : const <String, dynamic>{};
}

int? extractOptionalIntExtra(Object? extra, String key) {
  final data = extractMapExtra(extra);
  final value = data[key];
  return value is int ? value : null;
}

bool? extractOptionalBoolExtra(Object? extra, String key) {
  final data = extractMapExtra(extra);
  final value = data[key];
  return value is bool ? value : null;
}

const Set<String> _publicRoutePaths = {
  '/',
  '/login',
  '/signup',
  '/forgot-password',
  '/onboarding',
};

const List<String> _publicRoutePrefixes = ['/study/'];

bool isAuthRoutePath(String path) {
  return path == '/login' || path == '/signup' || path == '/forgot-password';
}

bool isProtectedRoutePath(String path) {
  if (_publicRoutePaths.contains(path)) return false;
  for (final prefix in _publicRoutePrefixes) {
    if (path.startsWith(prefix)) return false;
  }
  return true;
}

String? normalizePostAuthRedirect(String? from) {
  if (from == null || from.isEmpty) return null;
  final uri = Uri.tryParse(from);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  if (!uri.path.startsWith('/')) return null;
  if (isAuthRoutePath(uri.path)) return '/';
  return uri.toString();
}

String? resolveAppRedirect({
  required bool isAuthenticated,
  required String matchedLocation,
  required Uri currentUri,
}) {
  if (!isAuthenticated && isProtectedRoutePath(matchedLocation)) {
    return Uri(
      path: '/login',
      queryParameters: {'from': currentUri.toString()},
    ).toString();
  }

  if (isAuthenticated && isAuthRoutePath(matchedLocation)) {
    return normalizePostAuthRedirect(currentUri.queryParameters['from']) ?? '/';
  }

  return null;
}

class GoRouterRefreshStream extends ChangeNotifier {
  late final StreamSubscription<dynamic> _subscription;

  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen(
      (_) {
        notifyListeners();
      },
      onError: (e) {
        debugPrint('GoRouterRefreshStream error: $e');
      },
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// Shared slide+fade transition for all study-mode routes.
CustomTransitionPage<void> studyTransitionPage({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: StudyConstants.pageTransitionDuration,
    reverseTransitionDuration: const Duration(milliseconds: 260),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurveTween(curve: StudyConstants.pageTransitionCurve)
          .animate(animation);
      final slide = Tween<Offset>(
        begin: const Offset(0.08, 0),
        end: Offset.zero,
      ).animate(curved);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}

GoRouter createAppRouter({
  required SupabaseService supabaseService,
  required Listenable refreshListenable,
}) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: refreshListenable,
    redirect: (context, state) async {
      // Onboarding redirect
      bool hasSeenOnboarding = true;
      try {
        final settingsBox = Hive.box(AppConstants.hiveSettingsBox);
        hasSeenOnboarding =
            settingsBox.get(
                  AppConstants.settingHasSeenOnboarding,
                  defaultValue: false,
                )
                as bool;
      } catch (_) {
        // Hive box not available — skip onboarding to avoid a crash loop.
      }
      if (!hasSeenOnboarding &&
          state.matchedLocation == '/' &&
          state.matchedLocation != '/onboarding') {
        return '/onboarding';
      }

      final isAuthenticated = supabaseService.currentUser != null;
      final baseRedirect = resolveAppRedirect(
        isAuthenticated: isAuthenticated,
        matchedLocation: state.matchedLocation,
        currentUri: state.uri,
      );
      if (baseRedirect != null) return baseRedirect;

      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const DashboardScreen()),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/folders',
        builder: (context, state) => const FolderManagementScreen(),
      ),
      GoRoute(
        path: '/search',
        builder: (context, state) => const SearchScreen(),
      ),
      GoRoute(
        path: '/classes',
        builder: (context, state) => const ClassesScreen(),
      ),
      GoRoute(
        path: '/classes/:classId',
        builder: (context, state) {
          final classId = state.pathParameters['classId'] ?? '';
          return ClassDetailScreen(classId: classId);
        },
      ),
      GoRoute(
        path: '/classes/:classId/student/:studentId',
        builder: (context, state) {
          final classId = state.pathParameters['classId'] ?? '';
          final studentId = state.pathParameters['studentId'] ?? '';
          final extra = extractMapExtra(state.extra);
          final studentName =
              (extra['studentName'] as String?)?.trim().isNotEmpty == true
              ? extra['studentName'] as String
              : studentId;
          return ClassStudentDetailScreen(
            classId: classId,
            studentId: studentId,
            studentName: studentName,
          );
        },
      ),
      GoRoute(path: '/scan', builder: (context, state) => const QrScanScreen()),
      GoRoute(
        path: '/achievements',
        builder: (context, state) => const AchievementsScreen(),
      ),
      GoRoute(
        path: '/conversation/history',
        builder: (context, state) => const ConversationHistoryScreen(),
        routes: [
          GoRoute(
            path: ':transcriptId',
            builder: (context, state) {
              var transcript = state.extra as ConversationTranscript?;
              if (transcript == null) {
                final id = state.pathParameters['transcriptId'] ?? '';
                final raw = Hive.box(AppConstants.hiveSettingsBox)
                    .get('conversation_transcripts') as String?;
                if (raw != null && raw.isNotEmpty) {
                  final all = ConversationTranscript.decodeList(raw);
                  transcript = all.cast<ConversationTranscript?>().firstWhere(
                    (t) => t!.id == id,
                    orElse: () => null,
                  );
                }
              }
              if (transcript == null) {
                return const Scaffold(
                  body: Center(child: Text('Transcript not found')),
                );
              }
              return TranscriptDetailScreen(transcript: transcript);
            },
          ),
        ],
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/signup',
        builder: (context, state) => const SignupScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/import',
        builder: (context, state) => const WebImportScreen(),
      ),
      GoRoute(
        path: '/import/review',
        builder: (context, state) {
          final studySet = extractStudySetExtra(state.extra);
          if (studySet == null) {
            return const DashboardScreen();
          }
          return ReviewImportScreen(studySet: studySet);
        },
      ),
      GoRoute(
        path: '/import/photo',
        builder: (context, state) => const PhotoImportScreen(),
      ),
      GoRoute(
        path: '/review',
        pageBuilder: (context, state) {
          final data = extractMapExtra(state.extra);
          final tags = (data['tags'] as List<dynamic>?)?.cast<String>();
          final maxCards = extractOptionalIntExtra(state.extra, 'maxCards');
          final challengeMode =
              extractOptionalBoolExtra(state.extra, 'challengeMode') ?? false;
          final challengeTarget = extractOptionalIntExtra(
            state.extra,
            'challengeTarget',
          );
          final revengeCardIds = (data['revengeCardIds'] as List<dynamic>?)
              ?.cast<String>();
          return studyTransitionPage(
            key: state.pageKey,
            child: SrsReviewScreen(
              filterTags: tags,
              maxCards: maxCards,
              challengeMode: challengeMode,
              challengeTarget: challengeTarget,
              revengeCardIds: revengeCardIds,
            ),
          );
        },
      ),
      GoRoute(
        path: '/review/summary',
        pageBuilder: (context, state) {
          final data = extractMapExtra(state.extra);
          return studyTransitionPage(
            key: state.pageKey,
            child: ReviewSummaryScreen(
              totalReviewed: data['totalReviewed'] as int? ?? 0,
              againCount: data['againCount'] as int? ?? 0,
              hardCount: data['hardCount'] as int? ?? 0,
              goodCount: data['goodCount'] as int? ?? 0,
              easyCount: data['easyCount'] as int? ?? 0,
              challengeMode: data['challengeMode'] as bool? ?? false,
              challengeTarget: data['challengeTarget'] as int?,
              challengeCompleted: data['challengeCompleted'] as bool? ?? false,
              isRevengeMode: data['isRevengeMode'] as bool? ?? false,
              revengeCardCount: data['revengeCardCount'] as int? ?? 0,
              sessionXp: data['sessionXp'] as int? ?? 0,
              maxCombo: data['maxCombo'] as int? ?? 0,
            ),
          );
        },
      ),
      GoRoute(
        path: '/revenge',
        pageBuilder: (context, state) => studyTransitionPage(
          key: state.pageKey,
          child: const RevengeDetailScreen(),
        ),
      ),
      GoRoute(
        path: '/revenge/quiz',
        pageBuilder: (context, state) {
          final data = extractMapExtra(state.extra);
          final cardIds =
              (data['cardIds'] as List<dynamic>?)?.cast<String>() ?? [];
          return studyTransitionPage(
            key: state.pageKey,
            child: RevengeQuizScreen(cardIds: cardIds),
          );
        },
      ),
      GoRoute(
        path: '/profile/edit',
        builder: (context, state) => const ProfileEditScreen(),
      ),
      GoRoute(path: '/about', builder: (context, state) => const AboutScreen()),
      GoRoute(
        path: '/about/privacy',
        builder: (context, state) =>
            const LegalDocumentScreen(type: LegalDocType.privacy),
      ),
      GoRoute(
        path: '/about/terms',
        builder: (context, state) =>
            const LegalDocumentScreen(type: LegalDocType.terms),
      ),
      GoRoute(
        path: '/about/youth',
        builder: (context, state) =>
            const LegalDocumentScreen(type: LegalDocType.youth),
      ),
      GoRoute(path: '/stats', builder: (context, state) => const StatsScreen()),
      GoRoute(
        path: '/admin',
        redirect: (context, state) async {
          final isAdmin = await supabaseService.isCurrentUserAdmin();
          if (!isAdmin) return '/';
          return null;
        },
        builder: (context, state) => const AdminManagementScreen(),
      ),
      GoRoute(
        path: '/community',
        builder: (context, state) => const CommunityScreen(),
      ),
      GoRoute(
        path: '/community/notifications',
        builder: (context, state) => const CommunityNotificationsScreen(),
      ),
      GoRoute(
        path: '/profile/:userId',
        builder: (context, state) {
          final userId = state.pathParameters['userId']!;
          return UserProfileScreen(userId: userId);
        },
      ),
      GoRoute(
        path: '/speaking/:setId',
        builder: (context, state) {
          final setId = state.pathParameters['setId']!;
          return SpeakingPracticeScreen(setId: setId);
        },
      ),
      GoRoute(
        path: '/study/custom',
        builder: (context, state) => const CustomStudyScreen(),
      ),
      GoRoute(
        path: '/edit/:setId',
        builder: (context, state) {
          final setId = state.pathParameters['setId']!;
          return CardEditorScreen(setId: setId);
        },
      ),
      GoRoute(
        path: '/study/:setId',
        builder: (context, state) {
          final setId = state.pathParameters['setId']!;
          return StudyModePickerScreen(setId: setId);
        },
        routes: [
          GoRoute(
            path: 'conversation',
            builder: (context, state) {
              final setId = state.pathParameters['setId']!;
              return ConversationSetupScreen(setId: setId);
            },
            routes: [
              GoRoute(
                path: 'practice',
                builder: (context, state) {
                  final setId = state.pathParameters['setId']!;
                  final data = extractMapExtra(state.extra);
                  final turns = data['turns'] as int? ?? 5;
                  final difficulty = data['difficulty'] as String? ?? 'medium';
                  final scenarioId = data['scenarioId'] as String?;
                  return ConversationPracticeScreen(
                    setId: setId,
                    turns: turns,
                    difficulty: difficulty,
                    scenarioId: scenarioId,
                  );
                },
                routes: [
                  GoRoute(
                    path: 'summary',
                    builder: (context, state) {
                      final setId = state.pathParameters['setId']!;
                      final transcript =
                          state.extra as ConversationTranscript?;
                      if (transcript == null) {
                        return const Scaffold(
                          body: Center(child: Text('No transcript data')),
                        );
                      }
                      return ConversationSummaryScreen(
                        transcript: transcript,
                        setId: setId,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: 'srs',
            pageBuilder: (context, state) {
              final setId = state.pathParameters['setId']!;
              return studyTransitionPage(
                key: state.pageKey,
                child: SrsReviewScreen(setId: setId),
              );
            },
          ),
          GoRoute(
            path: 'flashcards',
            pageBuilder: (context, state) {
              final setId = state.pathParameters['setId']!;
              return studyTransitionPage(
                key: state.pageKey,
                child: FlashcardScreen(setId: setId),
              );
            },
          ),
          GoRoute(
            path: 'speaking',
            builder: (context, state) {
              final setId = state.pathParameters['setId']!;
              return SpeakingPracticeScreen(setId: setId);
            },
          ),
          GoRoute(
            path: 'learn',
            builder: (context, state) {
              final setId = state.pathParameters['setId']!;
              return LearnModeScreen(setId: setId);
            },
          ),
          GoRoute(
            path: 'quiz',
            pageBuilder: (context, state) {
              final setId = state.pathParameters['setId']!;
              final data = extractMapExtra(state.extra);
              final settings = data['settings'] as QuizSettings?;
              final questionCount = extractOptionalIntExtra(
                state.extra,
                'questionCount',
              );
              return studyTransitionPage(
                key: state.pageKey,
                child: QuizScreen(
                  setId: setId,
                  questionCount: questionCount,
                  settings: settings,
                ),
              );
            },
            routes: [
              GoRoute(
                path: 'result',
                pageBuilder: (context, state) {
                  final setId = state.pathParameters['setId']!;
                  final elapsedSeconds =
                      extractOptionalIntExtra(state.extra, 'elapsedSeconds') ??
                      0;
                  final score =
                      extractOptionalIntExtra(state.extra, 'score') ?? 0;
                  final total =
                      extractOptionalIntExtra(state.extra, 'total') ?? 0;
                  final accuracy =
                      extractOptionalIntExtra(state.extra, 'accuracy') ?? 0;
                  final paceScore =
                      extractOptionalIntExtra(state.extra, 'paceScore') ?? 50;
                  final reinforcementScore =
                      extractOptionalIntExtra(
                        state.extra,
                        'reinforcementScore',
                      ) ??
                      0;
                  final reinforcementTotal =
                      extractOptionalIntExtra(
                        state.extra,
                        'reinforcementTotal',
                      ) ??
                      0;
                  return studyTransitionPage(
                    key: state.pageKey,
                    child: QuizCompleteScreen(
                      setId: setId,
                      elapsedSeconds: elapsedSeconds,
                      score: score,
                      total: total,
                      accuracy: accuracy,
                      paceScore: paceScore,
                      reinforcementScore: reinforcementScore,
                      reinforcementTotal: reinforcementTotal,
                    ),
                  );
                },
              ),
            ],
          ),
          GoRoute(
            path: 'share',
            builder: (context, state) {
              final setId = state.pathParameters['setId']!;
              return ShareScreen(setId: setId);
            },
          ),
          GoRoute(
            path: 'match',
            pageBuilder: (context, state) {
              final setId = state.pathParameters['setId']!;
              final pairCount = extractOptionalIntExtra(
                state.extra,
                'pairCount',
              );
              return studyTransitionPage(
                key: state.pageKey,
                child: MatchingGameScreen(setId: setId, pairCount: pairCount),
              );
            },
            routes: [
              GoRoute(
                path: 'result',
                pageBuilder: (context, state) {
                  final setId = state.pathParameters['setId']!;
                  final elapsedSeconds =
                      extractOptionalIntExtra(state.extra, 'elapsedSeconds') ??
                      0;
                  final accuracy =
                      extractOptionalIntExtra(state.extra, 'accuracy') ?? 0;
                  final attempts =
                      extractOptionalIntExtra(state.extra, 'attempts') ?? 0;
                  final pairCount = extractOptionalIntExtra(
                    state.extra,
                    'pairCount',
                  );
                  return studyTransitionPage(
                    key: state.pageKey,
                    child: MatchingCompleteScreen(
                      setId: setId,
                      elapsedSeconds: elapsedSeconds,
                      accuracy: accuracy,
                      attempts: attempts,
                      pairCount: pairCount,
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

GoRouter? _globalRouter;

/// Callback invoked when the router becomes ready.
/// Set by main.dart to flush pending deep links.
VoidCallback? onRouterReady;

/// Navigate from outside the widget tree (e.g. HomeWidget deep links).
/// Returns true if the router was available and navigation occurred.
bool navigateFromDeepLink(String path) {
  final router = _globalRouter;
  if (router != null) {
    router.go(path);
    return true;
  }
  return false;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final supabaseService = ref.watch(supabaseServiceProvider);
  final refreshListenable = GoRouterRefreshStream(
    supabaseService.authStateChanges,
  );
  ref.onDispose(refreshListenable.dispose);

  final router = createAppRouter(
    supabaseService: supabaseService,
    refreshListenable: refreshListenable,
  );
  _globalRouter = router;
  // Flush any deep link that arrived before the router was ready.
  onRouterReady?.call();
  ref.onDispose(() {
    if (_globalRouter == router) _globalRouter = null;
    router.dispose();
  });
  return router;
});
