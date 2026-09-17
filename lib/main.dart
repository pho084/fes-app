import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FES Schul-App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const DashboardPage(),
    );
  }
}

// ==========================================
// 1. DASHBOARD GRID (REIHENFOLGE GEÄNDERT)
// ==========================================
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FES Pforzheim'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          children: [
            _buildTile(
              context,
              title: 'Moodle',
              icon: Icons.school,
              color: Colors.orange,
              url: 'https://moodle.fes-pforzheim.de/moodle/',
            ),
            _buildTile(
              context,
              title: 'Vertretungsplan',
              icon: Icons.calendar_today,
              color: Colors.green,
              url: 'https://moodle.fes-pforzheim.de/moodle/course/view.php?id=1517',
            ),
            _buildTile(
              context,
              title: 'Krankmeldung',
              icon: Icons.assignment_turned_in,
              color: Colors.red,
              url: 'https://www.fes-pforzheim.de/entschuldigungsformular',
            ),
            _buildTile(
              context,
              title: 'Homepage',
              icon: Icons.language,
              color: Colors.blue,
              url: 'https://fes-pforzheim.de',
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
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => WebViewPage(initialUrl: url),
            ),
          );
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 2. WEBVIEW ENGINE & NATIVE DOWNLOAD BRIDGE
// ==========================================
class WebViewPage extends StatefulWidget {
  final String initialUrl;
  const WebViewPage({super.key, required this.initialUrl});

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

            // Vertretungsplan / HTML-Ressourcen explizit erlauben!
            // Wenn der Link auf eine HTML-Ansicht oder Kurs-View zeigt -> normal laden
            if (lowerUrl.contains('redirect=1') || 
                (lowerUrl.contains('/mod/resource/view.php') && !lowerUrl.contains('forcedownload=1'))) {
              return NavigationDecision.navigate;
            }

            // Nur echte Downloads abfangen (pluginfile.php, forcedownload=1, direkte Dateiendungen)
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
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
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
          title: const Text('FES Schul-App'),
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
              onPressed: () => Navigator.of(context).pop(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
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