import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
//plattformspezifische Cookie-Steuerung:
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF1A5276); // Schul-Blau

    return MaterialApp(
      title: 'FES-APP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6F7),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

// ==========================================
// 1. DASHBOARD GRID (GRÖSSERES LOGO)
// ==========================================
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'FES-APP',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // Logo-Container mit mehr Höhe
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Image.asset(
                'assets/images/fes_logo.png',
                height: 200, // logo höhe
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.school,
                  size: 60,
                  color: Color(0xFF1A5276),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Wähle einen Bereich aus:',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                children: [
                  _buildTile(
                    context,
                    title: 'Moodle',
                    icon: Icons.school_rounded,
                    color: const Color(0xFFE67E22),
                    url: 'https://moodle.fes-pforzheim.de/moodle/',
                  ),
                  _buildTile(
                    context,
                    title: 'Vertretungsplan',
                    icon: Icons.calendar_month_rounded,
                    color: const Color(0xFF27AE60),
                    url: 'https://moodle.fes-pforzheim.de/moodle/course/view.php?id=1517',
                  ),
                  _buildTile(
                    context,
                    title: 'Krankmeldung',
                    icon: Icons.assignment_turned_in_rounded,
                    color: const Color(0xFFC0392B),
                    url: 'https://www.fes-pforzheim.de/entschuldigungsformular',
                  ),
                  _buildTile(
                    context,
                    title: 'Homepage',
                    icon: Icons.language_rounded,
                    color: const Color(0xFF2980B9),
                    url: 'https://fes-pforzheim.de',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required String title,
    required IconData icon,
    required Color color,
    required String url,
  }) {
    return Card(
      elevation: 2,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => WebViewPage(initialUrl: url, title: title),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 36, color: color),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF34495E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. WEBVIEW ENGINE & DUAL ROUTING HANDLER
// ==========================================
class WebViewPage extends StatefulWidget {
  final String initialUrl;
  final String title;
  const WebViewPage({super.key, required this.initialUrl, required this.title});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  late final WebViewController _controller;
  bool _isLoading = true;

@override
void initState() {
  super.initState();
  _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel(
      'FileDownloader',
      onMessageReceived: (JavaScriptMessage message) {
        _handleDownloadedData(message.message);
      },
    )
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _isLoading = true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _isLoading = false);
        },
        onNavigationRequest: (NavigationRequest request) async {
          final url = request.url;
          final lowerUrl = url.toLowerCase();

          if (lowerUrl.contains('redirect=1') || 
              (lowerUrl.contains('/mod/resource/view.php') && !lowerUrl.contains('forcedownload=1'))) {
            return NavigationDecision.navigate;
          }

          bool isDownload = lowerUrl.contains('forcedownload=1') ||
              (lowerUrl.contains('pluginfile.php') && 
               !lowerUrl.contains('.html') && 
               !lowerUrl.contains('.htm'));

          if (isDownload) {
            _triggerJsDownload(url);
            return NavigationDecision.prevent;
          }

          return NavigationDecision.navigate;
        },
      ),
    )
    ..loadRequest(Uri.parse(widget.initialUrl));

// Korrigierte Android Cookie-Steuerung für persistente Sessions
    if (_controller.platform is AndroidWebViewController) {
      AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      ).setAcceptThirdPartyCookies(
        _controller.platform as AndroidWebViewController,
        true,
      );
    }
  }

  void _triggerJsDownload(String url) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Datei wird verarbeitet...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    final jsScript = '''
      (function() {
        fetch("$url")
          .then(response => {
            const disposition = response.headers.get('Content-Disposition');
            let filename = "$url".split('/').pop().split('?')[0] || "moodle_datei";
            if (disposition && disposition.indexOf('filename=') !== -1) {
              const matches = /filename[^;=\\n]*=((['"]).*?\\2|[^;\\n]*)/.exec(disposition);
              if (matches != null && matches[1]) {
                filename = matches[1].replace(/['"]/g, '');
              }
            }
            return response.blob().then(blob => ({ blob, filename }));
          })
          .then(({ blob, filename }) => {
            const reader = new FileReader();
            reader.onloadend = function() {
              const base64data = reader.result.split(',')[1];
              const payload = JSON.stringify({ filename: filename, data: base64data });
              FileDownloader.postMessage(payload);
            };
            reader.readAsDataURL(blob);
          })
          .catch(err => {
            console.error("Download Error", err);
          });
      })();
    ''';

    _controller.runJavaScript(jsScript);
  }

  Future<void> _handleDownloadedData(String jsonString) async {
    try {
      final Map<String, dynamic> payload = jsonDecode(jsonString);
      String fileName = payload['filename'] ?? 'moodle_datei.bin';
      String base64Data = payload['data'] ?? '';

      if (base64Data.isEmpty) return;

      fileName = Uri.decodeFull(fileName);
      fileName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      if (!fileName.contains('.')) fileName = '$fileName.bin';

      final bytes = base64Decode(base64Data);
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsBytes(bytes);

      final result = await OpenFilex.open(file.path);

      if (result.type != ResultType.done && mounted) {
        await Share.shareXFiles(
          [XFile(file.path)],
          text: 'Datei speichern oder teilen: $fileName',
        );
      }
    } catch (e) {
      debugPrint('Fehler bei Datenverarbeitung: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          await _controller.goBack();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _controller.canGoBack()) {
                await _controller.goBack();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.home),
              tooltip: 'Zum Dashboard',
              onPressed: () => Navigator.of(context).pop(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Neu laden',
              onPressed: () => _controller.reload(),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_isLoading) const LinearProgressIndicator(minHeight: 3),
            Expanded(child: WebViewWidget(controller: _controller)),
          ],
        ),
      ),
    );
  }
}