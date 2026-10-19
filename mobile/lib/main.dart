// Horus Hotel — application Android (coque Flutter).
// Elle affiche l'application web Horus Hotel et ajoute les fonctions natives :
// impression (tickets 80/58 mm, A4), envoi de photos, liens WhatsApp/téléphone, partage, écran hors connexion.
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const String kAppUrl = 'https://guyayekkweeli-glitch.github.io/horus-hotel/';
const String kAppHost = 'guyayekkweeli-glitch.github.io';
const String kAppPath = '/horus-hotel';
const Color kBrand = Color(0xFFB4532A);
const Color kBg = Color(0xFFF6EFE4);
const Color kInk = Color(0xFF2B1E16);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: kBg,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: kBg,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(const HorusApp());
}

class HorusApp extends StatelessWidget {
  const HorusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Horus Hotel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: kBrand, surface: kBg),
        scaffoldBackgroundColor: kBg,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final WebViewController _web;
  int _progress = 0;
  bool _offline = false;
  bool _firstLoad = true;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(kBg)
      ..setUserAgent(null)
      ..addJavaScriptChannel('HorusApp', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => setState(() => _progress = p),
        onPageFinished: (_) => setState(() { _firstLoad = false; _offline = false; }),
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) setState(() => _offline = true);
        },
        onNavigationRequest: (req) async {
          final uri = Uri.tryParse(req.url);
          if (uri == null) return NavigationDecision.prevent;
          final internal = (uri.host == kAppHost && uri.path.startsWith(kAppPath)) || uri.scheme == 'about' || uri.scheme == 'data' || uri.scheme == 'blob';
          if (internal) return NavigationDecision.navigate;
          // WhatsApp, téléphone, e-mail, cartes, sites externes : application du téléphone
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
      ));
    _setUserAgent();
    _setupAndroid();
    _web.loadRequest(Uri.parse(kAppUrl));
    Connectivity().onConnectivityChanged.listen((r) {
      final online = !r.contains(ConnectivityResult.none);
      if (online && _offline) _reload();
    });
  }

  Future<void> _setUserAgent() async {
    final ua = await _web.getUserAgent();
    await _web.setUserAgent('${ua ?? ''} HorusApp/1.0');
  }

  Future<void> _setupAndroid() async {
    final c = _web.platform;
    if (c is AndroidWebViewController) {
      await c.setMediaPlaybackRequiresUserGesture(true);
      AndroidWebViewController.enableDebugging(false);
      // Champs « choisir une photo » (chambres, produits, logo, justificatifs)
      await c.setOnShowFileSelector((params) async {
        final picker = ImagePicker();
        final multiple = params.mode == FileSelectorMode.openMultiple;
        ImageSource? source = params.isCaptureEnabled ? ImageSource.camera : await _askSource();
        if (source == null) return <String>[];
        if (source == ImageSource.camera) {
          final shot = await picker.pickImage(source: ImageSource.camera, imageQuality: 80, maxWidth: 1800);
          return shot == null ? <String>[] : [Uri.file(shot.path).toString()];
        }
        if (multiple) {
          final list = await picker.pickMultiImage(imageQuality: 80, maxWidth: 1800);
          return list.map((x) => Uri.file(x.path).toString()).toList();
        }
        final one = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1800);
        return one == null ? <String>[] : [Uri.file(one.path).toString()];
      });
    }
  }

  Future<ImageSource?> _askSource() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: kBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Prendre une photo'), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choisir dans la galerie'), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // Messages envoyés par l'application web (window.HorusApp.postMessage)
  Future<void> _onMessage(JavaScriptMessage m) async {
    Map<String, dynamic> msg;
    try { msg = jsonDecode(m.message) as Map<String, dynamic>; } catch (_) { return; }
    switch (msg['type']) {
      case 'print':
        final html = (msg['html'] ?? '') as String;
        final title = (msg['title'] ?? 'Horus Hotel') as String;
        await Printing.layoutPdf(
          name: title,
          onLayout: (format) => Printing.convertHtml(format: format, html: html),
        );
        break;
      case 'open':
        final u = Uri.tryParse((msg['url'] ?? '') as String);
        if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
        break;
    }
  }

  Future<void> _reload() async {
    setState(() { _offline = false; _progress = 0; });
    await _web.reload();
  }

  Future<bool> _handleBack() async {
    // Ferme d'abord une fenêtre ouverte dans l'application, puis revient en arrière
    final closed = await _web.runJavaScriptReturningResult(
        "(function(){var m=document.getElementById('modal');if(m&&!m.classList.contains('hidden')&&!m.dataset.locked){closeModal();return 'closed';}return 'none';})()");
    if (closed.toString().contains('closed')) return false;
    if (await _web.canGoBack()) { await _web.goBack(); return false; }
    if (!mounted) return true;
    final quit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitter Horus Hotel ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Rester')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quitter')),
        ],
      ),
    );
    return quit == true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _handleBack()) SystemNavigator.pop();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(children: [
            WebViewWidget(controller: _web),
            if (_progress < 100 && !_offline)
              Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(value: _progress / 100, minHeight: 3, color: kBrand, backgroundColor: Colors.transparent)),
            if (_firstLoad && !_offline)
              Container(color: kBg, alignment: Alignment.center, child: Column(mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.asset('assets/icon.png', width: 96, height: 96)),
                const SizedBox(height: 18),
                const Text('Horus Hotel', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: kInk)),
                const SizedBox(height: 18),
                const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: kBrand)),
              ])),
            if (_offline) _OfflineView(onRetry: _reload),
          ]),
        ),
      ),
    );
  }
}

class _OfflineView extends StatelessWidget {
  const _OfflineView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      padding: const EdgeInsets.all(32),
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.wifi_off_rounded, size: 56, color: kBrand),
        const SizedBox(height: 16),
        const Text('Pas de connexion internet', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: kInk), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text('Vérifiez vos données mobiles ou le Wi-Fi. Vos informations sont en sécurité et réapparaîtront dès le retour du réseau.',
            textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF6B5646))),
        const SizedBox(height: 22),
        FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Réessayer'),
            style: FilledButton.styleFrom(backgroundColor: kBrand, minimumSize: const Size(200, 52))),
      ]),
    );
  }
}
