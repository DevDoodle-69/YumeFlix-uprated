import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../together_service.dart';
import 'host_crown_icon.dart';

/// Glassmorphism chat over the video: the film stays visible but blurred
/// behind the panel, so a message never means missing the scene.
///
/// Text only (2.13.0 — image sending was removed), reply-by-long-press
/// with a quote above the composer. There is no emoji picker in the app
/// UI (2.12.0): a user who wants an emoji in a message types it on their
/// own system keyboard — message text is user content, not app UI — and
/// the app itself renders none.
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final service = widget.service;
    final messages = service.messages;
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
                                  'Say hi to start the watch party',
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
                                    onReply: () =>
                                        setState(() => _replyTo = message),
                                  );
                                },
                              ),
                      ),
                      if (_replyTo != null) _replyQuote(),
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
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
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
        border: Border(left: BorderSide(color: colorScheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              // Replying to a name, not a "Friend": the quoted message's
              // sender is who typed it (or HOST for the host).
              'Replying to ${togetherChatSenderDisplayName(reply, mine: reply.senderId == widget.service.clientId)}: ${reply.quoteText}',
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

  Widget _composerRow(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
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
                  // 2.11.0: every bubble names its sender — `You` for own
                  // messages, `HOST` + crown icon for the room creator,
                  // the typed name for a guest — so everyone knows who
                  // said what. Crown icon + label, never colour alone.
                  if (!mine && message.senderRole == 'host')
                    HostIdentityLabel(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      iconSize: 11,
                      color: textColor.withValues(alpha: 0.8),
                    )
                  else
                    Flexible(
                      child: Text(
                        togetherChatSenderDisplayName(message, mine: mine),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.8),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
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
