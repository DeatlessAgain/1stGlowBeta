import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DeathlessDownloaderApp());
}

// -----------------------------------------------------------------------------
// Root Application
// -----------------------------------------------------------------------------
class DeathlessDownloaderApp extends StatelessWidget {
  const DeathlessDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Deathless Downloader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFFB800), // Signature Amber Gold
          primary: const Color(0xFFFFB800),
          secondary: const Color(0xFF1E293B),
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 1,
          iconTheme: IconThemeData(color: Color(0xFF0F172A)),
          titleTextStyle: TextStyle(
            color: Color(0xFF0F172A),
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// -----------------------------------------------------------------------------
// Data Models matching our FastAPI backend schema
// -----------------------------------------------------------------------------
class FormatItem {
  final String formatId;
  final String ext;
  final String? resolution;
  final String? qualityLabel;
  final String? filesizeReadable;
  final String url;
  final bool hasVideo;
  final bool hasAudio;
  final bool isVideoOnly;
  final bool isAudioOnly;
  final bool isCombined;
  final String? vcodec;
  final String? acodec;

  FormatItem({
    required this.formatId,
    required this.ext,
    this.resolution,
    this.qualityLabel,
    this.filesizeReadable,
    required this.url,
    required this.hasVideo,
    required this.hasAudio,
    required this.isVideoOnly,
    required this.isAudioOnly,
    required this.isCombined,
    this.vcodec,
    this.acodec,
  });

  factory FormatItem.fromJson(Map<String, dynamic> json) {
    return FormatItem(
      formatId: json['format_id']?.toString() ?? 'unknown',
      ext: json['ext'] ?? 'mp4',
      resolution: json['resolution'],
      qualityLabel: json['quality_label'] ?? json['format_note'] ?? json['resolution'],
      filesizeReadable: json['filesize_readable'],
      url: json['url'] ?? '',
      hasVideo: json['has_video'] ?? false,
      hasAudio: json['has_audio'] ?? false,
      isVideoOnly: json['is_video_only'] ?? false,
      isAudioOnly: json['is_audio_only'] ?? false,
      isCombined: json['is_combined'] ?? false,
      vcodec: json['vcodec'],
      acodec: json['acodec'],
    );
  }
}

class ExtractionResult {
  final String id;
  final String title;
  final String? uploader;
  final String? durationFormatted;
  final String? thumbnail;
  final int totalFormats;
  final List<FormatItem> videoFormats;
  final List<FormatItem> audioFormats;
  final List<FormatItem> combinedFormats;

  ExtractionResult({
    required this.id,
    required this.title,
    this.uploader,
    this.durationFormatted,
    this.thumbnail,
    required this.totalFormats,
    required this.videoFormats,
    required this.audioFormats,
    required this.combinedFormats,
  });

  factory ExtractionResult.fromJson(Map<String, dynamic> json) {
    final videoList = (json['video_formats'] as List? ?? [])
        .map((f) => FormatItem.fromJson(f as Map<String, dynamic>))
        .toList();

    final audioList = (json['audio_formats'] as List? ?? [])
        .map((f) => FormatItem.fromJson(f as Map<String, dynamic>))
        .toList();

    final combinedList = (json['combined_formats'] as List? ?? [])
        .map((f) => FormatItem.fromJson(f as Map<String, dynamic>))
        .toList();

    return ExtractionResult(
      id: json['id']?.toString() ?? '',
      title: json['title'] ?? 'Untitled Media',
      uploader: json['uploader'],
      durationFormatted: json['duration_formatted'],
      thumbnail: json['thumbnail'],
      totalFormats: json['total_formats'] ?? (videoList.length + audioList.length),
      videoFormats: videoList,
      audioFormats: audioList,
      combinedFormats: combinedList,
    );
  }
}

// -----------------------------------------------------------------------------
// Home Screen
// -----------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  // Backend host: 10.0.2.2 for Android Emulator, localhost for iOS/Web
  String _apiBaseUrl = 'http://10.0.2.2:8000';
  bool _isLoading = false;
  final List<Map<String, dynamic>> _downloadHistory = [];

  // Supported site shortcuts
  final List<Map<String, dynamic>> _platforms = [
    {
      'name': 'YouTube',
      'icon': Icons.play_circle_fill,
      'color': const Color(0xFFFF0000),
      'sample': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    },
    {
      'name': 'Instagram',
      'icon': Icons.camera_alt,
      'color': const Color(0xFFE1306C),
      'sample': 'https://www.instagram.com/reel/sample/',
    },
    {
      'name': 'Facebook',
      'icon': Icons.facebook,
      'color': const Color(0xFF1877F2),
      'sample': 'https://www.facebook.com/watch/?v=sample',
    },
    {
      'name': 'TikTok',
      'icon': Icons.music_note,
      'color': const Color(0xFF010101),
      'sample': 'https://www.tiktok.com/@creator/video/sample',
    },
  ];

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Paste URL from Clipboard
  Future<void> _pasteFromClipboard() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (clipboardData?.text != null && clipboardData!.text!.isNotEmpty) {
      setState(() {
        _urlController.text = clipboardData.text!.trim();
      });
      _extractMedia(_urlController.text);
    } else {
      _showSnackbar('Clipboard is empty');
    }
  }

  // Call FastAPI backend /extract endpoint
  Future<void> _extractMedia(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) {
      _showSnackbar('Please enter or paste a valid media URL');
      return;
    }

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      _showSnackbar('URL must start with http:// or https://');
      return;
    }

    _focusNode.unfocus();
    setState(() {
      _isLoading = true;
    });

    try {
      final uri = Uri.parse('$_apiBaseUrl/extract').replace(
        queryParameters: {'url': url},
      );

      final response = await http.get(uri).timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          throw Exception('Connection timed out. Ensure the FastAPI backend is running.');
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final extractionResult = ExtractionResult.fromJson(data);

        if (!mounted) return;
        _showDownloadBottomSheet(extractionResult);
      } else {
        String errorMsg = 'Failed to extract media (HTTP ${response.statusCode})';
        try {
          final errJson = json.decode(response.body);
          if (errJson['detail'] != null) {
            errorMsg = errJson['detail'];
          }
        } catch (_) {}

        _showErrorDialog('Extraction Failed', errorMsg);
      }
    } catch (e) {
      _showErrorDialog(
        'Connection Error',
        'Could not connect to FastAPI server at $_apiBaseUrl.\n\n'
        'Details: ${e.toString().replaceAll("Exception: ", "")}\n\n'
        'Note: If testing on Android Emulator, use "http://10.0.2.2:8000". '
        'If testing on a physical device, use your machine\'s local Wi-Fi IP.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Bottom Sheet format chooser (Classic Snaptube UX)
  void _showDownloadBottomSheet(ExtractionResult data) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (_, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  // Drag handle
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 8),
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  // Media Header Preview
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: data.thumbnail != null
                              ? Image.network(
                                  data.thumbnail!,
                                  width: 90,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 90,
                                    height: 60,
                                    color: Colors.grey[200],
                                    child: const Icon(Icons.video_library, color: Colors.grey),
                                  ),
                                )
                              : Container(
                                  width: 90,
                                  height: 60,
                                  color: Colors.grey[200],
                                  child: const Icon(Icons.video_library, color: Colors.grey),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                data.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  if (data.uploader != null) ...[
                                    Text(
                                      data.uploader!,
                                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  if (data.durationFormatted != null)
                                    Text(
                                      '• ${data.durationFormatted}',
                                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 1),

                  // Format Tabs (Music vs Video)
                  TabBar(
                    indicatorColor: const Color(0xFFFFB800),
                    indicatorWeight: 3,
                    labelColor: const Color(0xFF0F172A),
                    unselectedLabelColor: Colors.grey[500],
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    tabs: [
                      Tab(
                        icon: const Icon(Icons.music_note, size: 20),
                        text: 'Music (${data.audioFormats.length})',
                      ),
                      Tab(
                        icon: const Icon(Icons.video_camera_back, size: 20),
                        text: 'Video (${data.videoFormats.length})',
                      ),
                    ],
                  ),

                  // Formats List
                  Expanded(
                    child: TabBarView(
                      children: [
                        // Audio Tab
                        data.audioFormats.isEmpty
                            ? const Center(child: Text('No separate audio formats available'))
                            : ListView.separated(
                                controller: scrollController,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                itemCount: data.audioFormats.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (context, idx) {
                                  final item = data.audioFormats[idx];
                                  return _buildFormatTile(item, isAudio: true, mediaTitle: data.title);
                                },
                              ),

                        // Video Tab
                        data.videoFormats.isEmpty
                            ? const Center(child: Text('No video formats available'))
                            : ListView.separated(
                                controller: scrollController,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                itemCount: data.videoFormats.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (context, idx) {
                                  final item = data.videoFormats[idx];
                                  return _buildFormatTile(item, isAudio: false, mediaTitle: data.title);
                                },
                              ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // Single Format Row with Download Button
  Widget _buildFormatTile(FormatItem item, {required bool isAudio, required String mediaTitle}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          // Quality badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isAudio ? const Color(0xFFFFFBEB) : const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isAudio ? const Color(0xFFFDE68A) : const Color(0xFFBFDBFE),
              ),
            ),
            child: Text(
              item.qualityLabel ?? (isAudio ? 'Audio' : (item.resolution ?? 'Video')),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: isAudio ? const Color(0xFFB45309) : const Color(0xFF1D4ED8),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Details: Format & Size
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      item.ext.toUpperCase(),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (item.isCombined)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'A+V Muxed',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF15803D),
                          ),
                        ),
                      ),
                  ],
                ),
                Text(
                  item.filesizeReadable ?? 'Dynamic Stream Size',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),

          // Download Action Button
          ElevatedButton.icon(
            onPressed: () => _triggerDownload(item, mediaTitle),
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Download'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFB800),
              foregroundColor: const Color(0xFF0F172A),
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  // Handle Download action
  void _triggerDownload(FormatItem item, String title) {
    Navigator.of(context).pop(); // Close bottom sheet

    setState(() {
      _downloadHistory.insert(0, {
        'title': title,
        'format': item.qualityLabel ?? item.resolution ?? item.ext,
        'ext': item.ext,
        'time': 'Just now',
        'url': item.url,
      });
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.file_download_done, color: Color(0xFFFFB800)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Starting download: $title (${item.ext.toUpperCase()})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Copy URL',
          textColor: const Color(0xFFFFB800),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: item.url));
            _showSnackbar('Direct stream URL copied to clipboard');
          },
        ),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSettingsDialog() {
    final controller = TextEditingController(text: _apiBaseUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backend API Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your FastAPI host address:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'http://10.0.2.2:8000',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '• Android Emulator: http://10.0.2.2:8000\n'
              '• Web / iOS Simulator: http://localhost:8000\n'
              '• Physical Device: http://<YOUR_PC_IP>:8000',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _apiBaseUrl = controller.text.trim();
              });
              Navigator.pop(ctx);
              _showSnackbar('API Base URL updated');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showSnackbar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 18)),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFB800),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.play_arrow, color: Color(0xFF0F172A), size: 18),
            ),
            const SizedBox(width: 8),
            const Text('Deathless Downloader', style: TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Backend API Settings',
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Top Search & URL Bar
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.search, color: Color(0xFF64748B), size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      focusNode: _focusNode,
                      decoration: const InputDecoration(
                        hintText: 'Search or paste video link...',
                        hintStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
                        border: InputBorder.none,
                      ),
                      style: const TextStyle(fontSize: 14),
                      onSubmitted: (val) => _extractMedia(val),
                    ),
                  ),
                  if (_urlController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                      onPressed: () {
                        setState(() {
                          _urlController.clear();
                        });
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.content_paste, size: 20, color: Color(0xFF475569)),
                    tooltip: 'Paste from clipboard',
                    onPressed: _pasteFromClipboard,
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    onPressed: _isLoading ? null : () => _extractMedia(_urlController.text),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFB800),
                      foregroundColor: const Color(0xFF0F172A),
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                          )
                        : const Text('Search', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 2. Supported Platforms Grid
            const Text(
              'Supported Sites',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 12),

            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _platforms.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.85,
              ),
              itemBuilder: (context, index) {
                final p = _platforms[index];
                return InkWell(
                  onTap: () {
                    setState(() {
                      _urlController.text = p['sample'];
                    });
                    _extractMedia(p['sample']);
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFF1F5F9)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: (p['color'] as Color).withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(p['icon'], color: p['color'], size: 24),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          p['name'],
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 28),

            // 3. Quick Tips Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lightbulb_outline, color: Color(0xFFD97706), size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Fast yt-dlp Extraction',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Color(0xFF92400E),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Paste any YouTube, Instagram, Facebook, or TikTok video link above. '
                          'The app calls your FastAPI endpoint at $_apiBaseUrl/extract to inspect all qualities.',
                          style: const TextStyle(fontSize: 12, color: Color(0xFFB45309)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 4. Recent Downloads / Activity
            if (_downloadHistory.isNotEmpty) ...[
              const Text(
                'Recent Downloads',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 10),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _downloadHistory.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, idx) {
                  final d = _downloadHistory[idx];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                d['title'] ?? 'Media',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                              Text(
                                '${d['format']} • ${d['time']}',
                                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 16),
                          tooltip: 'Copy Direct URL',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: d['url']));
                            _showSnackbar('Direct download URL copied');
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
