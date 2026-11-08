import 'dart:convert';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../chat_image_chunks.dart';
import '../models.dart';
import '../together_service.dart';

/// Glassmorphism chat over the video: the film stays visible but blurred
/// behind the panel, so a message never means missing the scene.
///
/// Text, a quick-emoji row (system keyboard emoji via the normal keyboard —
/// no heavy emoji package), reply-by-long-press with a quote above the
/// composer, and photos via file_picker, up to 5 MB (2.8.0 — was ~120 KB).
/// Photos travel chunked over the relay (32 KiB pieces, SHA-256 checked on
/// reassembly), so a big photo never stalls the room as one giant packet;
/// sending / receiving progress shows as a slim row above the composer
/// while a transfer is in flight.
///
/// Message contents are never logged anywhere.
class TogetherChatPanel extends StatefulWidget {
  const TogetherChatPanel({
    required this.service,
    required this.onClose,
    super.key,
  });

  final TogetherService service;
  final VoidCallback onClose;

  @override
  State<TogetherChatPanel> createState() => _TogetherChatPanelState();
}

class _TogetherChatPanelState extends State<TogetherChatPanel> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  TogetherChatMessage? _replyTo;
  bool _sendingImage = false;

  static const List<String> _quickEmoji = <String>[
    '😂',
    '❤️',
    '🔥',
    '😮',
    '👏',
    '😢',
  ];

  @override
  void initState() {
    super.initState();
    widget.service.setChatPanelOpen(true);
    widget.service.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    widget.service.setChatPanelOpen(false);
    widget.service.removeListener(_onServiceChanged);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {});
    // New messages land at the bottom; follow them while the panel is open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendText() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final reply = _replyTo;
    _composer.clear();
    setState(() => _replyTo = null);
    await widget.service.sendChatText(
      text,
      replyToId: reply?.id,
      replyToText: reply?.quoteText,
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _sendImage() async {
    if (_sendingImage) return;
    setState(() => _sendingImage = true);
    try {
      // file_picker 13: static pickFiles returns the picked files directly
      // (no FilePicker.platform / FilePickerResult / withData); bytes are
      // read through the picked file.
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (picked.isEmpty) return;
      final bytes = await picked.first.readAsBytes();
      if (bytes.isEmpty) return;
      final result = await widget.service.sendChatImage(bytes);
      if (!mounted) return;
      switch (result) {
        case TogetherImageSendResult.sent:
          break;
        case TogetherImageSendResult.notConnected:
          _showSnack(
            'Not connected to the Together relay — the photo wasn’t sent. '
            'Try again once you’re reconnected.',
          );
        case TogetherImageSendResult.unreadable:
          _showSnack(
            'That file isn’t a readable photo — JPEG, PNG, WebP or GIF.',
          );
        case TogetherImageSendResult.tooLarge:
          _showSnack(
            'That photo is still over 5 MB after shrinking — '
            'try a smaller one.',
          );
      }
    } finally {
      if (mounted) setState(() => _sendingImage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final service = widget.service;
    final messages = service.messages;
    final transfers = service.imageTransfers;
    final width = MediaQuery.sizeOf(context).width;
    final panelWidth = width > 560 ? 380.0 : width * 0.88;

    return Align(
      alignment: Alignment.centerRight,
      // Safe area below the composer: in landscape the gesture bar /
      // system bar sits under the panel, and the input row must stay
      // above it. A no-op while the player hides the system UI.
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        bottom: true,
        child: Padding(
          padding: const EdgeInsets.only(right: 12, top: 12, bottom: 12),
          child: SizedBox(
            width: panelWidth,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surface.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Column(
                  children: [
                    _header(context),
                    const Divider(height: 1),
                    Expanded(
                      child: messages.isEmpty
                          ? Center(
                              child: Text(
                                'Say hi to start the watch party 👋',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                final message = messages[index];
                                final mine =
                                    message.senderId == service.clientId;
                                return _MessageBubble(
                                  message: message,
                                  mine: mine,
                                  onReply: () => setState(
                                    () => _replyTo = message,
                                  ),
                                );
                              },
                            ),
                    ),
                    _quickEmojiRow(),
                    if (_replyTo != null) _replyQuote(),
                    if (transfers.isNotEmpty) _transferRows(transfers),
                    _composerRow(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }

  Widget _header(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.group_rounded, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Together chat',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (widget.service.otp != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Room ${widget.service.otp}',
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Close chat',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _quickEmojiRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          for (final emoji in _quickEmoji)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  _composer.text += emoji;
                  _composer.selection = TextSelection.fromPosition(
                    TextPosition(offset: _composer.text.length),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(emoji, style: const TextStyle(fontSize: 20)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _replyQuote() {
    final reply = _replyTo!;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: colorScheme.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Replying to ${reply.senderLabel}: ${reply.quoteText}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          InkWell(
            onTap: () => setState(() => _replyTo = null),
            child: const Icon(Icons.close_rounded, size: 16),
          ),
        ],
      ),
    );
  }

  /// Slim progress rows for photos in flight (2.8.0 chunked transfer):
  /// "Sending photo… 45%" / "Receiving photo… 45%", one row per transfer,
  /// above the composer. A row disappears the moment its photo lands as a
  /// message (or fails, in which case the room sees an honest line).
  Widget _transferRows(List<TogetherImageTransfer> transfers) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final transfer in transfers)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    transfer.isOutgoing
                        ? Icons.upload_rounded
                        : Icons.download_rounded,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: transfer.progress,
                        minHeight: 4,
                        backgroundColor: colorScheme.onSurface.withValues(
                          alpha: 0.15,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${transfer.isOutgoing ? 'Sending' : 'Receiving'} photo… '
                    '${(transfer.progress * 100).round()}%',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _composerRow(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          IconButton(
            icon: _sendingImage
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.image_outlined),
            tooltip: 'Send a photo',
            onPressed: _sendImage,
          ),
          Expanded(
            child: TextField(
              controller: _composer,
              decoration: InputDecoration(
                hintText: 'Message…',
                filled: true,
                fillColor: colorScheme.surface.withValues(alpha: 0.6),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendText(),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filled(
            icon: const Icon(Icons.send_rounded, size: 20),
            tooltip: 'Send',
            onPressed: _sendText,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.onReply,
  });

  final TogetherChatMessage message;
  final bool mine;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final time = DateFormat.Hm().format(
      DateTime.fromMillisecondsSinceEpoch(message.timestampMs),
    );
    final bubbleColor = mine
        ? colorScheme.primary.withValues(alpha: 0.85)
        : Colors.white.withValues(alpha: 0.12);
    final textColor = mine ? Colors.white : colorScheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onReply,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.62,
          ),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(mine ? 14 : 4),
              bottomRight: Radius.circular(mine ? 4 : 14),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.replyToText != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '↩ ${message.replyToText!}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.75),
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.senderLabel,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.8),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    time,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              if (message.isImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    base64Decode(message.imageBase64!),
                    fit: BoxFit.cover,
                    errorBuilder: (context, _, _) => const Text(
                      'Photo could not be shown',
                    ),
                  ),
                )
              else
                Text(
                  message.text ?? '',
                  style: TextStyle(color: textColor, fontSize: 14),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
