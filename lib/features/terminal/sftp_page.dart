import 'dart:async';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/app_store.dart';
import '../../core/device_bridge.dart';
import '../../core/sessions.dart';

class SftpPage extends StatefulWidget {
  const SftpPage({super.key, required this.session, required this.store});
  final WorkspaceSession session;
  final AppStore store;
  @override
  State<SftpPage> createState() => _SftpPageState();
}

class _SftpPageState extends State<SftpPage> {
  SftpClient? client;
  List<SftpName> entries = [];
  String directory = '/';
  String? error;
  bool loading = false;
  int transferred = 0;
  String task = '';
  bool cancelled = false;
  bool _transferInProgress = false;
  Future<void> Function()? retryTask;
  void publishProgress() {
    if (task.isNotEmpty) widget.session.transferStatus = task;
    widget.session.transferBytes = transferred;
    widget.session.retryTransfer = retryTask;
    widget.session.cancelTransfer = task.isEmpty
        ? null
        : () {
            cancelled = true;
          };
    widget.session.updateTransfer();
  }

  String child(String path, String name) =>
      path == '/' ? '/$name' : '${path.replaceFirst(RegExp(r'/$'), '')}/$name';

  bool validName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      name.codeUnits.every(
        (unit) => unit != 47 && unit != 92 && unit > 31 && unit != 127,
      );
  Future<void> load(String path) async {
    final c = client;
    if (c == null || loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final canonical = await c.absolute(path);
      final rows = await c.listdir(canonical);
      rows.sort((a, b) {
        final d = (b.attr.isDirectory ? 1 : 0).compareTo(
          a.attr.isDirectory ? 1 : 0,
        );
        return d != 0
            ? d
            : a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      if (mounted) {
        setState(() {
          entries = rows..removeWhere((e) => e.filename == '.');
          directory = canonical;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法读取该目录。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> pickUpload() async {
    if (client == null || loading || _transferInProgress) return;
    _transferInProgress = true;
    cancelled = false;
    String? documentUri;
    String? partialPath;
    String? backupPath;
    String? targetPath;
    SftpFile? remote;
    try {
      final file = await deviceBridge.invokeMethod<Map>('pickUpload');
      if (file == null) return;
      final uri = documentUri = file['uri']! as String;
      if (!mounted) return;
      final name = file['name']! as String;
      final size = file['size'] as int? ?? 0;
      if (!validName(name)) throw const FormatException();
      final path = targetPath = child(directory, name);
      var exists = false;
      try {
        final attrs = await client!.stat(path, followLink: false);
        if (attrs.isDirectory) throw StateError('目标是目录');
        exists = true;
      } on SftpStatusError catch (error) {
        if (error.code != SftpStatusCode.noSuchFile) rethrow;
      }
      if (!mounted || (exists && !await confirm('覆盖 $name？')) || !mounted) {
        return;
      }
      cancelled = false;
      transferred = 0;
      retryTask = pickUpload;
      setState(() => task = '上传 $name');
      widget.session.transferTotal = size > 0 ? size : null;
      publishProgress();
      partialPath =
          '$path.pocket-ssh-${DateTime.now().microsecondsSinceEpoch}.part';
      remote = await client!.open(
        partialPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.exclusive |
            SftpFileOpenMode.write,
      );
      while (!cancelled) {
        final chunk = await deviceBridge.invokeMethod<Uint8List>(
          'readChunk',
          uri,
        );
        if (chunk == null) break;
        transferred += chunk.length;
        await remote.writeBytes(
          chunk,
          offset: (transferred - chunk.length).toInt(),
        );
        if (mounted) setState(() {});
        publishProgress();
      }
      if (cancelled) throw StateError('传输已取消');
      await remote.close();
      remote = null;
      if (exists) {
        backupPath =
            '$path.pocket-ssh-${DateTime.now().microsecondsSinceEpoch}.bak';
        await client!.rename(path, backupPath);
      }
      try {
        await client!.rename(partialPath, path);
        partialPath = null;
      } catch (_) {
        if (backupPath != null) {
          await client!.rename(backupPath, path);
          backupPath = null;
        }
        rethrow;
      }
      if (backupPath != null) {
        final backup = backupPath;
        backupPath = null;
        try {
          await client!.remove(backup);
        } catch (_) {}
      }
      retryTask = null;
      await deviceBridge.invokeMethod<void>('closeDocument', uri);
      documentUri = null;
      await load(directory);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('上传完成')));
      }
    } catch (_) {
      retryTask = pickUpload;
      widget.session.transferStatus = cancelled ? '上传已取消' : '上传失败';
      widget.session.retryTransfer = retryTask;
      if (mounted) {
        setState(
          () => error = cancelled ? '上传已取消，未替换原文件。' : '上传失败；重试会重新读取本地文件。',
        );
      }
    } finally {
      try {
        await remote?.close();
      } catch (_) {}
      _transferInProgress = false;
      if (partialPath != null && client != null) {
        try {
          await client!.remove(partialPath);
        } catch (_) {}
      }
      if (backupPath != null && client != null) {
        try {
          await client!.rename(backupPath, targetPath!);
        } catch (_) {}
      }
      if (documentUri != null) {
        try {
          await deviceBridge.invokeMethod<void>('closeDocument', documentUri);
        } catch (_) {}
      }
      if (mounted) setState(() => task = '');
      if (widget.session.transferStatus != '上传失败' &&
          widget.session.transferStatus != '上传已取消') {
        widget.session.transferStatus = null;
        widget.session.retryTransfer = null;
      }
      widget.session.transferTotal = null;
      publishProgress();
    }
  }

  Future<void> download(SftpName entry) async {
    if (client == null || loading || _transferInProgress) return;
    _transferInProgress = true;
    cancelled = false;
    String? uri;
    SftpFile? remote;
    try {
      final target = await deviceBridge.invokeMethod<Map>(
        'createDownload',
        entry.filename,
      );
      if (target == null) return;
      if (!mounted) {
        await deviceBridge.invokeMethod<bool>('deleteDocument', target['uri']);
        return;
      }
      uri = target['uri']! as String;
      retryTask = () => download(entry);
      cancelled = false;
      transferred = 0;
      final file = await client!.stat(child(directory, entry.filename));
      widget.session.transferTotal = file.size;
      remote = await client!.open(
        child(directory, entry.filename),
        mode: SftpFileOpenMode.read,
      );
      setState(() => task = '下载 ${entry.filename}');
      publishProgress();
      await for (final chunk in remote.read()) {
        if (cancelled) break;
        await deviceBridge.invokeMethod<void>('writeChunk', {
          'uri': uri,
          'bytes': chunk,
        });
        transferred += chunk.length;
        if (mounted) setState(() {});
        publishProgress();
      }
      if (cancelled) throw StateError('传输已取消');
      await remote.close();
      remote = null;
      await deviceBridge.invokeMethod<void>('finishDownload', uri);
      uri = null;
      if (mounted && !cancelled) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('下载完成')));
      }
      retryTask = null;
      widget.session.transferStatus = null;
      widget.session.cancelTransfer = null;
    } catch (_) {
      if (uri != null) {
        try {
          await deviceBridge.invokeMethod<bool>('deleteDocument', uri);
          uri = null;
        } catch (_) {}
      }
      retryTask = () => download(entry);
      widget.session.transferStatus = cancelled ? '下载已取消' : '下载失败';
      widget.session.retryTransfer = retryTask;
      widget.session.cancelTransfer = () {
        cancelled = true;
      };
      if (mounted) {
        setState(
          () =>
              error = cancelled ? '下载已取消；未完成的本地文件需要自行删除。' : '下载失败，请检查连接和存储空间。',
        );
      }
    } finally {
      try {
        await remote?.close();
      } catch (_) {}
      _transferInProgress = false;
      if (uri != null) {
        await deviceBridge.invokeMethod<void>('closeDocument', uri);
      }
      if (mounted) setState(() => task = '');
      if (widget.session.transferStatus != '下载失败' &&
          widget.session.transferStatus != '下载已取消') {
        widget.session.transferStatus = null;
        widget.session.retryTransfer = null;
      }
      widget.session.transferTotal = null;
      publishProgress();
    }
  }

  Future<bool> confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('请确认'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('继续'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> action(String type, SftpName entry) async {
    final c = client!;
    final path = child(directory, entry.filename);
    if (type == 'delete' && !await confirm('永久删除 ${entry.filename}？')) return;
    try {
      if (type == 'delete') {
        if (entry.attr.isDirectory) {
          if (!await confirm('确认删除目录 ${entry.filename}？')) return;
          await c.rmdir(path);
        } else {
          await c.remove(path);
        }
      } else if (type == 'rename') {
        final value = await renameDialog(entry.filename);
        if (value == null || !validName(value)) return;
        await c.rename(path, child(directory, value));
      }
      await load(directory);
    } catch (_) {
      if (mounted) setState(() => error = '操作失败。目录必须为空才能删除。');
    }
  }

  Future<String?> renameDialog(String current) async {
    final text = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: text, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, text.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    text.dispose();
    return result;
  }

  Future<void> mkdir() async {
    final name = await renameDialog('');
    if (name == null || !validName(name)) return;
    try {
      await client!.mkdir(child(directory, name));
      await load(directory);
    } catch (_) {
      setState(() => error = '无法创建目录。');
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.session.connected) unawaited(initialize());
    widget.session.addListener(statusChanged);
  }

  void statusChanged() {
    if (!widget.session.connected && mounted) {
      setState(() => error = 'SSH 连接已断开。');
    }
  }

  Future<void> initialize() async {
    try {
      final c = await widget.session.connection.sftp();
      if (!mounted) {
        await c.close();
        return;
      }
      client = c;
      await load(directory);
    } catch (_) {
      if (mounted) setState(() => error = '服务器不支持 SFTP 或无法启动子系统。');
    }
  }

  @override
  void dispose() {
    cancelled = true;
    widget.session.transferStatus = null;
    widget.session.transferTotal = null;
    widget.session.retryTransfer = null;
    widget.session.cancelTransfer = null;
    widget.session.updateTransfer();
    unawaited(client?.close() ?? Future.value());
    widget.session.removeListener(statusChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.session.profile.name),
            Text(
              'SFTP  /  ${widget.session.profile.host}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '新建文件夹',
            onPressed: loading || _transferInProgress ? null : mkdir,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: '上传文件',
            onPressed: loading || _transferInProgress ? null : pickUpload,
            icon: const Icon(Icons.upload_file),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: loading ? null : () => load(directory),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border(bottom: BorderSide(color: colors.outlineVariant)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一级',
                  onPressed: directory == '/' || loading
                      ? null
                      : () => load(
                          directory
                                  .substring(0, directory.lastIndexOf('/'))
                                  .isEmpty
                              ? '/'
                              : directory.substring(
                                  0,
                                  directory.lastIndexOf('/'),
                                ),
                        ),
                  icon: const Icon(Icons.arrow_upward),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    directory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
          if (task.isNotEmpty) ...[
            LinearProgressIndicator(
              value:
                  widget.session.transferTotal == null ||
                      widget.session.transferTotal == 0
                  ? null
                  : (transferred / widget.session.transferTotal!).clamp(0, 1),
            ),
            Container(
              color: colors.surfaceContainerLow,
              child: ListTile(
                dense: true,
                title: Text(task),
                subtitle: Text('$transferred bytes transferred'),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: '取消传输',
                      onPressed: () => setState(() => cancelled = true),
                      icon: const Icon(Icons.close),
                    ),
                    IconButton(
                      tooltip: '重试',
                      onPressed: retryTask == null ? null : () => retryTask!(),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (error != null)
            Container(
              width: double.infinity,
              color: colors.errorContainer,
              padding: const EdgeInsets.all(14),
              child: Text(
                error!,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : entries.where((entry) => entry.filename != '..').isEmpty
                ? Center(
                    child: Text(
                      '此目录为空',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: entries.where((e) => e.filename != '..').length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      indent: 50,
                      color: colors.outlineVariant,
                    ),
                    itemBuilder: (context, index) {
                      final entry = entries
                          .where((e) => e.filename != '..')
                          .elementAt(index);
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        leading: Icon(
                          entry.attr.isDirectory
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          color: entry.attr.isDirectory
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        title: Text(entry.filename),
                        subtitle: Text(
                          entry.attr.size == null
                              ? ''
                              : formatSize(entry.attr.size!),
                        ),
                        onTap: entry.attr.isDirectory
                            ? () => load(child(directory, entry.filename))
                            : null,
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) => value == 'download'
                              ? download(entry)
                              : action(value, entry),
                          itemBuilder: (_) => [
                            if (!entry.attr.isDirectory)
                              const PopupMenuItem(
                                value: 'download',
                                child: Text('下载'),
                              ),
                            const PopupMenuItem(
                              value: 'rename',
                              child: Text('重命名'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

String formatSize(int size) => size < 1024
    ? '$size B'
    : size < 1048576
    ? '${(size / 1024).toStringAsFixed(1)} KB'
    : '${(size / 1048576).toStringAsFixed(1)} MB';
