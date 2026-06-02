import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:recall_app/features/import/utils/js_scraper.dart';
import 'package:recall_app/models/flashcard.dart';
import 'package:recall_app/models/study_set.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';

class WebImportScreen extends StatefulWidget {
  const WebImportScreen({super.key});

  @override
  State<WebImportScreen> createState() => _WebImportScreenState();
}

class _WebImportScreenState extends State<WebImportScreen> {
  late final WebViewController? _controller;
  late final TextEditingController _urlController;
  String _currentUrl = '';
  bool _isLoading = true;
  bool _isImporting = false;

  bool get _isOnSupportedPage =>
      Uri.tryParse(_currentUrl)?.pathSegments.isNotEmpty ?? false;

  /// The import WebView is a focused tool for finding and scraping Quizlet
  /// sets, not a general-purpose browser. Only Quizlet (the scrape target) and
  /// Google (the search launchpad) are reachable; everything else is blocked.
  static const Set<String> _allowedHostSuffixes = {
    'quizlet.com',
    'google.com',
    'gstatic.com',
    'googleusercontent.com',
  };

  static bool _isAllowedNavigation(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme == 'about' || uri.scheme == 'data') return true;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return _allowedHostSuffixes.any(
      (suffix) => host == suffix || host.endsWith('.$suffix'),
    );
  }

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: 'https://www.google.com');
    if (!kIsWeb) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              if (_isAllowedNavigation(request.url)) {
                return NavigationDecision.navigate;
              }
              return NavigationDecision.prevent;
            },
            onPageStarted: (url) {
              setState(() {
                _currentUrl = url;
                _isLoading = true;
                _urlController.text = url;
              });
            },
            onPageFinished: (url) {
              setState(() {
                _currentUrl = url;
                _isLoading = false;
                _urlController.text = url;
              });
            },
          ),
        )
        ..loadRequest(Uri.parse('https://www.google.com'));
    } else {
      _controller = null;
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _navigateToUrl() {
    if (_controller == null) return;
    var url = _urlController.text.trim();
    if (url.isEmpty) return;

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
      _urlController.text = url;
    }

    _controller.loadRequest(Uri.parse(url));
  }

  Future<void> _debugScrape() async {
    if (_controller == null) return;
    try {
      final result = await _controller.runJavaScriptReturningResult('''
        (function() {
          var info = [];
          try {
            var nd = document.getElementById('__NEXT_DATA__');
            var parsed = JSON.parse(nd.textContent);
            var pp = parsed.props.pageProps;
            var state = JSON.parse(pp.dehydratedReduxStateKey);

            var sp = state.setPage;
            info.push('setPage keys: ' + Object.keys(sp).join(', '));
            if (sp.set) {
              info.push('setPage.set keys: ' + Object.keys(sp.set).join(', '));
              if (sp.set.terms) info.push('setPage.set.terms: array len=' + sp.set.terms.length);
              if (sp.set.title) info.push('setPage.set.title: ' + sp.set.title);
            }
            if (sp.terms) {
              info.push('setPage.terms: type=' + typeof sp.terms);
              if (Array.isArray(sp.terms)) info.push('setPage.terms len=' + sp.terms.length);
            }

            var cd = state.cards;
            info.push('cards keys: ' + Object.keys(cd).join(', '));
            Object.keys(cd).forEach(function(k) {
              var v = cd[k];
              if (v && typeof v === 'object' && !Array.isArray(v)) {
                info.push('cards.' + k + ' keys: ' + Object.keys(v).slice(0, 8).join(', '));
              } else if (Array.isArray(v)) {
                info.push('cards.' + k + ': array len=' + v.length);
                if (v.length > 0) info.push('cards.' + k + '[0] keys: ' + Object.keys(v[0]).slice(0, 8).join(', '));
              } else {
                info.push('cards.' + k + ': ' + String(v).substring(0, 60));
              }
            });

            if (state.studiableData) {
              info.push('studiableData keys: ' + Object.keys(state.studiableData).join(', '));
            }

          } catch(e) {
            info.push('ERROR: ' + e.message);
          }

          var tt = document.querySelectorAll('.TermText');
          if (tt.length > 0) {
            info.push('TermText[0]: ' + tt[0].innerText.substring(0, 40));
            if (tt.length > 1) info.push('TermText[1]: ' + tt[1].innerText.substring(0, 40));
          }

          return info.join('\\n');
        })();
      ''');

      String debugStr = result.toString();
      if (debugStr.startsWith('"') && debugStr.endsWith('"')) {
        debugStr = debugStr.substring(1, debugStr.length - 1);
        debugStr = debugStr.replaceAll(r'\n', '\n');
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Debug Info'),
            content: SingleChildScrollView(
              child: SelectableText(debugStr, style: const TextStyle(fontSize: 12)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Debug error: $e')),
        );
      }
    }
  }

  Future<void> _scrapeAndImport() async {
    if (_controller == null) return;
    if (_isImporting) return;

    setState(() => _isImporting = true);
    try {
      await _expandMoreCardsBeforeScrape();
      final result = await _controller.runJavaScriptReturningResult(
        JsScraper.scrapeScript,
      );

      String encoded = result.toString();
      if (encoded.startsWith('"') && encoded.endsWith('"')) {
        encoded = encoded.substring(1, encoded.length - 1);
      }
      final jsonStr = Uri.decodeComponent(encoded);

      final data = json.decode(jsonStr) as Map<String, dynamic>;
      final title = data['title'] as String? ?? 'Imported Set';
      final cardsData = data['cards'] as List? ?? [];

      if (cardsData.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).noFlashcardsFound),
            ),
          );
        }
        return;
      }

      final cards = cardsData.map((c) {
        return Flashcard(
          id: const Uuid().v4(),
          term: c['term'] as String? ?? '',
          definition: c['definition'] as String? ?? '',
          imageUrl: c['imageUrl'] as String? ?? '',
        );
      }).toList();

      final studySet = StudySet(
        id: const Uuid().v4(),
        title: title,
        createdAt: DateTime.now(),
        cards: cards,
      );

      if (mounted) {
        context.push('/import/review', extra: studySet);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).importFailed('$e'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  Future<void> _expandMoreCardsBeforeScrape() async {
    if (_controller == null) return;

    int previousVisible = -1;
    int stableRounds = 0;

    // Try multiple rounds: click "show more" + scroll, then wait for lazy-load.
    for (var i = 0; i < 14 && stableRounds < 3; i++) {
      final raw = await _controller.runJavaScriptReturningResult('''
        (function() {
          var clicked = 0;
          var nodes = document.querySelectorAll('button, a, [role="button"]');
          var patterns = ['顯示更多', '更多', 'show more', 'see more', 'load more', 'more'];

          nodes.forEach(function(node) {
            var text = (node.innerText || node.textContent || '').trim().toLowerCase();
            if (!text) return;
            var match = patterns.some(function(p) { return text.indexOf(p) !== -1; });
            if (match) {
              try {
                node.click();
                clicked++;
              } catch (e) {}
            }
          });

          var visible = document.querySelectorAll('.TermText, [data-testid="TextContent"]').length;
          var maxY = Math.max(
            document.body ? document.body.scrollHeight : 0,
            document.documentElement ? document.documentElement.scrollHeight : 0
          );
          window.scrollTo(0, maxY);
          return String(clicked) + '|' + String(visible);
        })();
      ''');

      final parts = raw
          .toString()
          .replaceAll('"', '')
          .split('|')
          .map((s) => int.tryParse(s.trim()) ?? 0)
          .toList();
      final clicked = parts.isNotEmpty ? parts[0] : 0;
      final visible = parts.length > 1 ? parts[1] : 0;

      if (visible == previousVisible && clicked == 0) {
        stableRounds++;
      } else {
        stableRounds = 0;
      }
      previousVisible = visible;

      await Future.delayed(const Duration(milliseconds: 450));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(
          leading: const AppBackButton(),
          title: Text(l10n.importTitle),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.phone_iphone,
                      size: 56,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      Icons.phone_android,
                      size: 56,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.useAppToImport,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.webViewMobileOnly,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => context.go('/'),
                  child: Text(l10n.goBack),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(l10n.importFromRecall),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        enabled: !_isImporting,
                        decoration: InputDecoration(
                          hintText: l10n.enterRecallUrl,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surface,
                        ),
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) {
                          if (_isImporting) return;
                          _navigateToUrl();
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: _isImporting
                          ? null
                          : () async {
                              final data =
                                  await Clipboard.getData(Clipboard.kTextPlain);
                              if (data?.text != null &&
                                  data!.text!.trim().isNotEmpty) {
                                _urlController.text = data.text!.trim();
                                _navigateToUrl();
                              }
                            },
                      icon: const Icon(Icons.content_paste_rounded),
                      tooltip: l10n.paste,
                      style: IconButton.styleFrom(
                        foregroundColor: AppTheme.indigo,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filled(
                      onPressed: _isImporting ? null : _navigateToUrl,
                      icon: const Icon(Icons.arrow_forward_rounded),
                      style: IconButton.styleFrom(
                        backgroundColor: AppTheme.indigo,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isLoading)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: WebViewWidget(controller: _controller!),
              ),
            ],
          ),
          if (_isImporting)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.22),
                child: Center(
                  child: Container(
                    width: 200,
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '${l10n.importSet}...',
                          style: Theme.of(context).textTheme.titleSmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: _isOnSupportedPage
          ? GestureDetector(
              onLongPress: kDebugMode ? _debugScrape : null,
              child: FloatingActionButton.extended(
                onPressed: _isImporting ? null : _scrapeAndImport,
                icon: const Icon(Icons.download_rounded),
                label: Text(l10n.importSet),
              ),
            )
          : null,
    );
  }
}
