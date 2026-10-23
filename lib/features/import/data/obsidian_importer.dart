import 'package:abelnotes/core/platform/io.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:abelnotes/features/import/data/frontmatter.dart';
import 'package:abelnotes/features/import/data/import_limits.dart';
import 'package:abelnotes/features/import/data/import_models.dart';
import 'package:abelnotes/features/import/data/markdown_block_parser.dart';
import 'package:abelnotes/features/import/data/obsidian_syntax.dart';

/// Parses an Obsidian vault directory into an [ImportedNotebookDraft]:
/// one chapter per .md file (path-prefixed titles preserve the folder
/// hierarchy), vault attachments resolved Obsidian-style (exact path first,
/// then unique basename anywhere in the vault).
class ObsidianImporter {
  static const _imageExts = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'
  };

  /// Tooling folders whose notes are never user content (no warning).
  static const _noiseDirs = {
    '.obsidian', '.trash', '.git', '.github', '.svn', '.hg'
  };

  static const _maxInlineTags = 50;

  final _uuid = const Uuid();

  static String _decodeTarget(String target) {
    try {
      return Uri.decodeFull(target);
    } catch (_) {
      return target;
    }
  }

  Future<ImportedNotebookDraft> parse(
    String vaultPath, {
    void Function(ImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final root = Directory(vaultPath);
    final issues = <ImportIssue>[];
    final assets = <String, Uint8List>{};
    final assetKeyByHash = <String, String>{};
    final tags = <String>{};
    final inlineTags = <String>{};

    onProgress?.call(const ImportProgress(phase: ImportPhase.scanning));

    final mdFiles = <File>[];
    final attachmentIndex = <String, File>{}; // vault-relative path (lower)
    final basenameIndex = <String, List<File>>{}; // basename (lower)
    final noteByPath = <String, File>{}; // rel path without .md (lower)
    final noteByName = <String, File>{}; // basename without .md (lower)
    var hiddenSkipped = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: vaultPath);
      final segs = p.split(rel);
      final dirs = segs.sublist(0, segs.length - 1);
      final isMd = p.extension(entity.path).toLowerCase() == '.md';
      // Hidden folders (.obsidian, .trash, .git, ...) are tooling; hidden
      // dotfiles are noise, but a dot-named .md is a real note.
      if (dirs.any((d) => d.startsWith('.'))) {
        if (isMd && !dirs.any(_noiseDirs.contains)) hiddenSkipped++;
        continue;
      }
      if (segs.last.startsWith('.') && !isMd) continue;
      if (isMd) {
        mdFiles.add(entity);
        final noExt = rel.substring(0, rel.length - 3).replaceAll('\\', '/');
        noteByPath[noExt.toLowerCase()] = entity;
        noteByName.putIfAbsent(p.basename(noExt).toLowerCase(), () => entity);
      } else {
        attachmentIndex[rel.toLowerCase()] = entity;
        basenameIndex
            .putIfAbsent(p.basename(entity.path).toLowerCase(), () => [])
            .add(entity);
      }
    }
    mdFiles.sort((a, b) => a.path.compareTo(b.path));
    if (mdFiles.isEmpty) {
      throw const ImportException(ImportErrorCode.noMarkdownFiles);
    }
    if (hiddenSkipped > 0) {
      issues.add(ImportIssue(
        source: p.basename(vaultPath),
        code: ImportIssueCode.hiddenFoldersSkipped,
        count: hiddenSkipped,
      ));
    }

    /// Obsidian "shortest path" resolution: exact vault-relative path, then
    /// path relative to the current note, then unique basename.
    File? resolveAttachment(String target, String mdDir) {
      final decoded = _decodeTarget(target).replaceAll('\\', '/');
      final lower = decoded.toLowerCase();
      final exact = attachmentIndex[lower];
      if (exact != null) return exact;
      final relToNote =
          p.relative(p.normalize(p.join(mdDir, decoded)), from: vaultPath);
      final byNote = attachmentIndex[relToNote.toLowerCase()];
      if (byNote != null) return byNote;
      final byName = basenameIndex[p.basename(lower)];
      if (byName != null && byName.isNotEmpty) return byName.first;
      return null;
    }

    /// Reads a note's body for `![[Note]]` inlining (frontmatter stripped).
    ({String title, String body})? lookupNote(String target) {
      final key = target.replaceAll('\\', '/').toLowerCase();
      final f = noteByPath[key] ?? noteByName[p.basename(key)];
      if (f == null) return null;
      try {
        if (f.lengthSync() > ImportLimits.maxNoteBytes) return null;
        final dec = decodeNoteText(f.readAsBytesSync());
        if (dec == null) return null;
        return (
          title: p.basenameWithoutExtension(f.path),
          body: stripFrontmatter(dec.text).body,
        );
      } catch (_) {
        return null;
      }
    }

    final chapters = <ImportedChapterDraft>[];
    for (var i = 0; i < mdFiles.length; i++) {
      if (isCancelled?.call() ?? false) break;
      final file = mdFiles[i];
      final rel = p.relative(file.path, from: vaultPath);
      final title =
          p.split(rel).join(' / ').replaceAll(RegExp(r'\.md$', caseSensitive: false), '');
      onProgress?.call(ImportProgress(
        phase: ImportPhase.parsing,
        current: i,
        total: mdFiles.length,
        detail: title,
      ));

      String raw;
      try {
        final size = await file.length();
        if (size > ImportLimits.maxNoteBytes) {
          issues.add(ImportIssue(
            source: rel,
            code: ImportIssueCode.fileTooLarge,
            count: size >> 20,
          ));
          continue;
        }
        final dec = decodeNoteText(await file.readAsBytes());
        if (dec == null) {
          issues.add(ImportIssue(
              source: rel, code: ImportIssueCode.fileUnreadable));
          continue;
        }
        if (dec.fellBack) {
          issues.add(ImportIssue(
              source: rel, code: ImportIssueCode.encodingFallback));
        }
        raw = dec.text;
      } catch (_) {
        issues.add(
            ImportIssue(source: rel, code: ImportIssueCode.fileUnreadable));
        continue;
      }

      final fm = stripFrontmatter(raw);
      tags.addAll(fm.tags);
      final markdown = rewriteObsidianSyntax(
        fm.body,
        source: rel,
        issues: issues,
        lookupNote: lookupNote,
        selfKey: p.basenameWithoutExtension(rel).toLowerCase(),
      );
      if (inlineTags.length < _maxInlineTags) {
        inlineTags.addAll(extractInlineTags(markdown));
      }

      ImageResolution resolveImage(String src, String? alt) {
        if (src.startsWith('http://') || src.startsWith('https://')) {
          return ImageResolution.fail(ImportIssueCode.remoteImageSkipped, src);
        }
        final shown = _decodeTarget(src);
        final f = resolveAttachment(src, p.dirname(file.path));
        if (f == null) {
          return ImageResolution.fail(ImportIssueCode.imageNotFound, shown);
        }
        if (!_imageExts.contains(p.extension(f.path).toLowerCase())) {
          return ImageResolution.fail(
              ImportIssueCode.attachmentUnsupported, shown);
        }
        try {
          if (f.lengthSync() > ImportLimits.maxImageBytes) {
            return ImageResolution.fail(
                ImportIssueCode.attachmentTooLarge, shown);
          }
          final bytes = f.readAsBytesSync();
          final info = img.findDecoderForData(bytes)?.startDecode(bytes);
          if (info == null) {
            return ImageResolution.fail(
                ImportIssueCode.imageUnreadable, shown);
          }
          final hash = sha1.convert(bytes).toString();
          var key = assetKeyByHash[hash];
          if (key == null) {
            key = '${_uuid.v4()}_${p.basename(f.path)}';
            assetKeyByHash[hash] = key;
            assets[key] = bytes;
          }
          return ImageResolution.ok(
              ImageBlock(assetKey: key, pxW: info.width, pxH: info.height));
        } catch (_) {
          return ImageResolution.fail(ImportIssueCode.imageUnreadable, shown);
        }
      }

      final parser = MarkdownParser(
        resolveImage: resolveImage,
        onIssue: issues.add,
        sourceName: rel,
      );
      chapters.add(ImportedChapterDraft(
        title: title,
        blocks: parser.parse(markdown),
        sourceName: rel,
      ));
      // Yield so the progress dialog stays responsive on big vaults.
      await Future<void>.delayed(Duration.zero);
    }

    if (chapters.length > ImportLimits.maxChapterWarning) {
      issues.add(ImportIssue(
        source: p.basename(vaultPath),
        code: ImportIssueCode.tooManyChapters,
        count: chapters.length,
      ));
    }

    return ImportedNotebookDraft(
      title: p.basename(vaultPath),
      tags: (tags..addAll(inlineTags)).toList()..sort(),
      chapters: chapters,
      assets: assets,
      issues: issues,
    );
  }
}
