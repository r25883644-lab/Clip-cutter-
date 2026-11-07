import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

void main() => runApp(const ClipApp());

class ClipApp extends StatelessWidget {
  const ClipApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Clip Cutter',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
        home: const HomePage(),
      );
}

class Preset {
  final String name;
  final int w;
  final int h;
  const Preset(this.name, this.w, this.h);
}

const presets = <Preset>[
  Preset('Instagram Reels (9:16)', 1080, 1920),
  Preset('YouTube Shorts (9:16)', 1080, 1920),
  Preset('TikTok (9:16)', 1080, 1920),
  Preset('Square (1:1)', 1080, 1080),
  Preset('Landscape (16:9)', 1920, 1080),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? videoPath;
  double durationSec = 0;
  int clipLen = 30;
  bool interesting = true;
  final customCtrl = TextEditingController();
  final countCtrl = TextEditingController(text: '5');
  Preset preset = presets[0];
  bool busy = false;
  String status = 'पहले वीडियो चुनें';
  double progress = 0;

  Future<void> pickVideo() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.video);
    if (r == null || r.files.single.path == null) return;
    final path = r.files.single.path!;
    final info = await FFprobeKit.getMediaInformation(path);
    final d = double.tryParse(info.getMediaInformation()?.getDuration() ?? '') ?? 0;
    setState(() {
      videoPath = path;
      durationSec = d;
      status = 'वीडियो चुना गया: ${(d / 60).toStringAsFixed(1)} मिनट';
    });
  }

  Future<List<double>> findInteresting(int len, int count) async {
    final tmp = await getTemporaryDirectory();
    final f = '${tmp.path}/rms.txt';
    if (await File(f).exists()) await File(f).delete();

    await FFmpegKit.executeWithArguments([
      '-y',
      '-i', videoPath!,
      '-vn',
      '-af',
      'aresample=8000,asetnsamples=n=8000:p=0,astats=metadata=1:reset=1,'
          'ametadata=print:key=lavfi.astats.Overall.RMS_level:file=$f',
      '-f', 'null',
      '-',
    ]);

    if (!await File(f).exists()) return [];
    final lines = await File(f).readAsLines();
    final rms = <double>[];
    for (final l in lines) {
      if (l.contains('RMS_level=')) {
        final d = double.tryParse(l.split('=').last.trim());
        rms.add((d == null || d.isNaN || d.isInfinite) ? -90.0 : d.clamp(-90.0, 0.0).toDouble());
      }
    }
    final n = rms.length;
    if (n < len) return [];

    final p = List<double>.filled(n + 1, 0);
    final p2 = List<double>.filled(n + 1, 0);
    for (int i = 0; i < n; i++) {
      p[i + 1] = p[i] + rms[i];
      p2[i + 1] = p2[i] + rms[i] * rms[i];
    }

    final cands = <MapEntry<int, double>>[];
    for (int s = 0; s + len <= n; s++) {
      final mean = (p[s + len] - p[s]) / len;
      final variance = (p2[s + len] - p2[s]) / len - mean * mean;
      final std = sqrt(max(0.0, variance));
      cands.add(MapEntry(s, mean + 0.5 * std));
    }
    cands.sort((a, b) => b.value.compareTo(a.value));

    final picked = <int>[];
    for (final c in cands) {
      if (picked.length >= count) break;
      if (picked.every((x) => (x - c.key).abs() >= len)) picked.add(c.key);
    }
    picked.sort();
    return picked.map((e) => e.toDouble()).toList();
  }

  Future<void> cutClips() async {
    if (videoPath == null || durationSec <= 0) return;
    final wanted = int.tryParse(countCtrl.text.trim());

    setState(() {
      busy = true;
      progress = 0;
    });

    List<double> starts = [];
    if (interesting) {
      setState(() => status = 'दिलचस्प हिस्से ढूंढ रहा हूं...');
      starts = await findInteresting(clipLen, wanted ?? 5);
      if (starts.isEmpty) {
        starts = _sequentialStarts(wanted);
      }
    } else {
      starts = _sequentialStarts(wanted);
    }

    final tmp = await getTemporaryDirectory();
    int done = 0;
    for (int i = 0; i < starts.length; i++) {
      final start = starts[i];
      final remaining = durationSec - start;
      final len = remaining < clipLen ? remaining : clipLen.toDouble();
      final out = '${tmp.path}/clip_${i + 1}_${DateTime.now().millisecondsSinceEpoch}.mp4';

      setState(() => status = 'क्लिप ${i + 1} / ${starts.length} बन रही है...');

      final vf = 'scale=${preset.w}:${preset.h}:force_original_aspect_ratio=increase,'
          'crop=${preset.w}:${preset.h},setsar=1';

      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-ss', start.toStringAsFixed(2),
        '-i', videoPath!,
        '-t', len.toStringAsFixed(2),
        '-vf', vf,
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '23',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-movflags', '+faststart',
        out,
      ]);

      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        await Gal.putVideo(out, album: 'ClipCutter');
        await File(out).delete();
        done++;
      }
      setState(() => progress = (i + 1) / starts.length);
    }

    setState(() {
      busy = false;
      status = 'हो गया! $done क्लिप्स गैलरी (ClipCutter एल्बम) में सेव हुईं';
    });
  }

  List<double> _sequentialStarts(int? wanted) {
    final list = <double>[];
    int i = 0;
    while (true) {
      final s = i * clipLen;
      if (durationSec - s < 3) break;
      if (wanted != null && list.length >= wanted) break;
      list.add(s.toDouble());
      i++;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final lens = [10, 20, 30, 40, 50, 60];
    return Scaffold(
      appBar: AppBar(title: const Text('Clip Cutter')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            onPressed: busy ? null : pickVideo,
            icon: const Icon(Icons.video_library),
            label: const Text('एपिसोड / वीडियो चुनें'),
          ),
          if (videoPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(videoPath!.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          const SizedBox(height: 20),
          const Text('कैसी क्लिप्स चाहिए?', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('दिलचस्प'), icon: Icon(Icons.local_fire_department)),
              ButtonSegment(value: false, label: Text('क्रम से'), icon: Icon(Icons.format_list_numbered)),
            ],
            selected: {interesting},
            onSelectionChanged: busy ? null : (s) => setState(() => interesting = s.first),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: countCtrl,
            enabled: !busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'कितनी क्लिप्स चाहिए?',
              helperText: interesting ? 'जैसे 5 या 10' : 'खाली छोड़ें तो पूरी एपिसोड कटेगी',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const Text('हर क्लिप की लंबाई (सेकंड)', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final l in lens)
                ChoiceChip(
                  label: Text('$l s'),
                  selected: clipLen == l,
                  onSelected: busy ? null : (_) => setState(() => clipLen = l),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: customCtrl,
            enabled: !busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'या अपना सेकंड लिखें (जैसे 45)',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n >= 1) setState(() => clipLen = n);
            },
          ),
          const SizedBox(height: 20),
          const Text('साइज़ / प्लेटफ़ॉर्म', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final p in presets)
            RadioListTile<Preset>(
              dense: true,
              title: Text(p.name),
              subtitle: Text('${p.w} x ${p.h}'),
              value: p,
              groupValue: preset,
              onChanged: busy ? null : (v) => setState(() => preset = v!),
            ),
          const SizedBox(height: 12),
          Text('चुनी गई लंबाई: $clipLen सेकंड'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (busy || videoPath == null) ? null : cutClips,
            icon: const Icon(Icons.content_cut),
            label: const Text('क्लिप्स काटें'),
          ),
          const SizedBox(height: 16),
          if (busy) LinearProgressIndicator(value: progress == 0 ? null : progress),
          const SizedBox(height: 8),
          Text(status),
        ],
      ),
    );
  }
}
