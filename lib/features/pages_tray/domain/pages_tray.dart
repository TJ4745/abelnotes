import 'package:abelnotes/shared/models/ncnote_format.dart';

enum TrayMode { copy, move }

/// Most pages one tray holds; Copy/Move refuse beyond it.
const int kTrayPageCap = 200;

/// A page in the tray: its data and the entry it had in the source.
class TrayPage {
  final PageEntry entry;
  final PageData data;
  const TrayPage(this.entry, this.data);

  String get pageId => entry.pageId;

  /// Asset ids the page refers to (image elements and declared references).
  Set<String> get assetIds => {
        ...data.assetReferences,
        for (final el in data.layers.content)
          if (el is ImageElement && el.data.assetPath.isNotEmpty)
            el.data.assetPath,
        if (data.layers.background.pdfAsset != null)
          data.layers.background.pdfAsset!,
      };
}

/// Written before a move is applied to the destination, cleared once the
/// source edit is done; lets a restart finish an interrupted move.
class TrayJournal {
  final String destNotebookId;
  final List<String> newPageIds;
  const TrayJournal(this.destNotebookId, this.newPageIds);

  Map<String, dynamic> toJson() =>
      {'dest': destNotebookId, 'newPageIds': newPageIds};

  factory TrayJournal.fromJson(Map<String, dynamic> j) => TrayJournal(
      j['dest'] as String, (j['newPageIds'] as List).cast<String>());
}

class PagesTray {
  final String id;
  final TrayMode mode;
  final String sourceNotebookId;
  final String sourceTitle;

  /// Title of the chapter every page came from; null when mixed or none.
  final String? sourceChapterTitle;
  final bool mixedChapters;
  final List<TrayPage> pages;

  /// Set when a pending move lost its source: the tray is a copy now.
  final bool sourceDeleted;

  /// The tray is on disk (the pill's "Saved on this device").
  final bool saved;
  final TrayJournal? journal;

  /// PNG previews of the first pages, for the pill.
  final List<List<int>> thumbs;

  const PagesTray({
    required this.id,
    required this.mode,
    required this.sourceNotebookId,
    required this.sourceTitle,
    this.sourceChapterTitle,
    this.mixedChapters = false,
    required this.pages,
    this.sourceDeleted = false,
    this.saved = false,
    this.journal,
    this.thumbs = const [],
  });

  bool get isMove => mode == TrayMode.move;
  int get count => pages.length;
  Set<String> get pageIds => {for (final p in pages) p.pageId};
  Set<String> get assetIds => {for (final p in pages) ...p.assetIds};

  PagesTray copyWith({
    TrayMode? mode,
    bool? sourceDeleted,
    bool? saved,
    TrayJournal? journal,
    bool clearJournal = false,
    List<List<int>>? thumbs,
  }) =>
      PagesTray(
        id: id,
        mode: mode ?? this.mode,
        sourceNotebookId: sourceNotebookId,
        sourceTitle: sourceTitle,
        sourceChapterTitle: sourceChapterTitle,
        mixedChapters: mixedChapters,
        pages: pages,
        sourceDeleted: sourceDeleted ?? this.sourceDeleted,
        saved: saved ?? this.saved,
        journal: clearJournal ? null : (journal ?? this.journal),
        thumbs: thumbs ?? this.thumbs,
      );

  /// A deleted source turns a pending move into a copy.
  PagesTray asCopyOfDeletedSource() =>
      copyWith(mode: TrayMode.copy, sourceDeleted: true, clearJournal: true);
}
