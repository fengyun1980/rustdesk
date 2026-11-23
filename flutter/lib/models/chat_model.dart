import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:draggable_float_widget/draggable_float_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/mobile/pages/home_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;

import '../consts.dart';
import '../common.dart';
import '../common/widgets/overlay.dart';
import '../main.dart';
import 'chat_local_io.dart'
    if (dart.library.html) 'chat_local_stub.dart' as chat_local;
import 'model.dart';

class MessageKey {
  final String peerId;
  final int connId;
  bool get isOut => connId == ChatModel.clientModeID;

  MessageKey(this.peerId, this.connId);

  @override
  bool operator ==(other) {
    return other is MessageKey &&
        other.peerId == peerId &&
        other.isOut == isOut;
  }

  @override
  int get hashCode => peerId.hashCode ^ isOut.hashCode;
}

class MessageBody {
  ChatUser chatUser;
  List<ChatMessage> chatMessages;
  MessageBody(this.chatUser, this.chatMessages);

  void insert(ChatMessage cm) {
    chatMessages.insert(0, cm);
  }

  void clear() {
    chatMessages.clear();
  }
}

/// A single chunk of an image sent through the regular text chat channel.
class _ImageChunk {
  static final _header =
      RegExp(r'^\[\[RDIMG1:([0-9a-z]+):(\d+)/(\d+)\]\]');

  final String id;
  final int index;
  final int total;
  final String data;

  _ImageChunk(this.id, this.index, this.total, this.data);

  static _ImageChunk? tryParse(String text) {
    if (!text.startsWith('[[RDIMG1:')) return null;
    final match = _header.firstMatch(text);
    if (match == null) return null;
    final index = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (index == null || total == null) return null;
    return _ImageChunk(
        match.group(1)!, index, total, text.substring(match.end));
  }
}

class _IncomingImage {
  final int total;
  final List<String?> parts;
  Timer? timer;

  _IncomingImage(this.total) : parts = List<String?>.filled(total, null);

  /// Returns true once every chunk has been received.
  bool add(int index, String data) {
    if (index < 0 || index >= total) return false;
    parts[index] = data;
    return parts.every((e) => e != null);
  }
}

class ChatModel with ChangeNotifier {
  static final clientModeID = -1;

  // Images are split into chunks so they can go through the text-only chat
  // channel. Each chunk is sent as a normal chat message with a marker.
  static const _imageChunkSize = 24 * 1024; // base64 chars per message
  static const _imageMaxChunks = 400;
  final Map<String, _IncomingImage> _incomingImages = {};
  bool _waitingChatScreenshot = false;
  int _imageSeq = 0;

  bool get waitingChatScreenshot => _waitingChatScreenshot;

  /// Screenshot capture is only available on desktop when we are the
  /// controlling side (client mode).
  bool get canSendScreenshot {
    final session = parent.target;
    return !isWeb &&
        !isMobile &&
        session != null &&
        _currentKey.connId == clientModeID;
  }

  OverlayEntry? chatIconOverlayEntry;
  OverlayEntry? chatWindowOverlayEntry;

  bool isConnManager = false;

  RxBool isWindowFocus = true.obs;
  BlockableOverlayState _blockableOverlayState = BlockableOverlayState();
  final Rx<VoiceCallStatus> _voiceCallStatus = Rx(VoiceCallStatus.notStarted);
  final RxBool _softKeyboardRequested = false.obs;
  bool _usingPhysicalChatInput = false;

  Rx<VoiceCallStatus> get voiceCallStatus => _voiceCallStatus;
  RxBool get softKeyboardRequested => _softKeyboardRequested;

  TextEditingController textController = TextEditingController();
  RxInt mobileUnreadSum = 0.obs;
  MessageKey? latestReceivedKey;

  Offset chatWindowPosition = Offset(20, 80);

  void setChatWindowPosition(Offset position) {
    chatWindowPosition = position;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final buffer in _incomingImages.values) {
      buffer.timer?.cancel();
    }
    _incomingImages.clear();
    inputNode.removeListener(_updateChatInputControl);
    _restoreChatInputControl();
    textController.dispose();
    super.dispose();
  }

  final ChatUser me = ChatUser(
    id: Uuid().v4().toString(),
    firstName: translate("Me"),
  );

  late final Map<MessageKey, MessageBody> _messages = {};

  MessageKey _currentKey = MessageKey('', -2); // -2 is invalid value
  late bool _isShowCMSidePage = false;

  Map<MessageKey, MessageBody> get messages => _messages;

  MessageKey get currentKey => _currentKey;

  bool get isShowCMSidePage => _isShowCMSidePage;

  void setOverlayState(BlockableOverlayState blockableOverlayState) {
    _blockableOverlayState = blockableOverlayState;

    _blockableOverlayState.addMiddleBlockedListener((v) {
      if (!v) {
        isWindowFocus.value = false;
        if (isWindowFocus.value) {
          isWindowFocus.toggle();
        }
      }
    });
  }

  final WeakReference<FFI> parent;

  late final SessionID sessionId;
  late FocusNode inputNode;

  ChatModel(this.parent) {
    sessionId = parent.target!.sessionId;
    inputNode = FocusNode(
      onKey: (_, event) {
        bool isShiftPressed = event.isKeyPressed(LogicalKeyboardKey.shiftLeft);
        bool isEnterPressed = event.isKeyPressed(LogicalKeyboardKey.enter);

        // don't send empty messages
        if (isEnterPressed && isEnterPressed && textController.text.isEmpty) {
          return KeyEventResult.handled;
        }

        if (isEnterPressed && !isShiftPressed) {
          final ChatMessage message = ChatMessage(
            text: textController.text,
            user: me,
            createdAt: DateTime.now(),
          );
          send(message);
          textController.clear();
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
    );
  }

  ChatUser? get currentUser => _messages[_currentKey]?.chatUser;

  showChatIconOverlay({Offset offset = const Offset(200, 50)}) {
    if (chatIconOverlayEntry != null) {
      chatIconOverlayEntry!.remove();
    }
    // mobile check navigationBar
    final bar = navigationBarKey.currentWidget;
    if (bar != null) {
      if ((bar as BottomNavigationBar).currentIndex == 1) {
        return;
      }
    }

    final overlayState = _blockableOverlayState.state;
    if (overlayState == null) return;

    final overlay = OverlayEntry(builder: (context) {
      return DraggableFloatWidget(
        config: DraggableFloatWidgetBaseConfig(
          initPositionYInTop: false,
          initPositionYMarginBorder: 100,
          borderTopContainTopBar: true,
        ),
        child: FloatingActionButton(
          onPressed: () {
            if (chatWindowOverlayEntry == null) {
              showChatWindowOverlay();
            } else {
              hideChatWindowOverlay();
            }
          },
          backgroundColor: Theme.of(context).colorScheme.primary,
          child: SvgPicture.asset('assets/chat2.svg'),
        ),
      );
    });
    overlayState.insert(overlay);
    chatIconOverlayEntry = overlay;
  }

  hideChatIconOverlay() {
    if (chatIconOverlayEntry != null) {
      chatIconOverlayEntry!.remove();
      chatIconOverlayEntry = null;
    }
  }

  showChatWindowOverlay(
      {Offset? chatInitPos, bool requestSoftKeyboard = true}) {
    if (chatWindowOverlayEntry != null) return;
    isWindowFocus.value = true;
    _blockableOverlayState.setMiddleBlocked(true);

    final overlayState = _blockableOverlayState.state;
    if (overlayState == null) return;
    if (isMobile) {
      _softKeyboardRequested.value = requestSoftKeyboard;
      gFFI.invokeMethod("enable_soft_keyboard", true);
    }
    if (isMobile &&
        !gFFI.chatModel.currentKey.isOut && // not in remote page
        gFFI.chatModel.latestReceivedKey != null) {
      gFFI.chatModel.changeCurrentKey(gFFI.chatModel.latestReceivedKey!);
      gFFI.chatModel.mobileClearClientUnread(gFFI.chatModel.currentKey.connId);
    }
    final overlay = OverlayEntry(builder: (context) {
      return Listener(
          onPointerDown: (event) {
            _requestChatSoftKeyboard(event);
            if (!isWindowFocus.value) {
              isWindowFocus.value = true;
              _blockableOverlayState.setMiddleBlocked(true);
            }
          },
          child: DraggableChatWindow(
              position: chatInitPos ?? chatWindowPosition,
              width: 250,
              height: 350,
              chatModel: this));
    });
    overlayState.insert(overlay);
    chatWindowOverlayEntry = overlay;
    if (isMobile && !requestSoftKeyboard) {
      inputNode.addListener(_updateChatInputControl);
      _updateChatInputControl();
    }
    requestChatInputFocus();
  }

  hideChatWindowOverlay() {
    if (chatWindowOverlayEntry != null) {
      _blockableOverlayState.setMiddleBlocked(false);
      chatWindowOverlayEntry!.remove();
      chatWindowOverlayEntry = null;
      _softKeyboardRequested.value = false;
      inputNode.removeListener(_updateChatInputControl);
      _restoreChatInputControl();
      return;
    }
  }

  _isChatOverlayHide() =>
      ((!(isDesktop || isWebDesktop) && chatIconOverlayEntry == null) ||
          chatWindowOverlayEntry == null);

  toggleChatOverlay({Offset? chatInitPos, bool requestSoftKeyboard = true}) {
    if (_isChatOverlayHide()) {
      if (!isMobile) gFFI.invokeMethod("enable_soft_keyboard", true);
      if (!(isDesktop || isWebDesktop)) {
        showChatIconOverlay();
      }
      showChatWindowOverlay(
          chatInitPos: chatInitPos, requestSoftKeyboard: requestSoftKeyboard);
    } else {
      hideChatIconOverlay();
      hideChatWindowOverlay();
    }
  }

  hideChatOverlay() {
    if (!_isChatOverlayHide()) {
      hideChatIconOverlay();
      hideChatWindowOverlay();
    }
  }

  showChatPage(MessageKey key) async {
    if (isDesktop) {
      if (isConnManager) {
        if (!_isShowCMSidePage) {
          await toggleCMChatPage(key);
        }
      } else {
        if (_isChatOverlayHide()) {
          await toggleChatOverlay();
        }
      }
    } else {
      if (key.connId == clientModeID) {
        if (_isChatOverlayHide()) {
          await toggleChatOverlay();
        }
      }
    }
  }

  toggleCMChatPage(MessageKey key) async {
    if (gFFI.chatModel.currentKey != key) {
      gFFI.chatModel.changeCurrentKey(key);
    }
    await toggleCMSidePage();
  }

  toggleCMFilePage() async {
    await toggleCMSidePage();
  }

  var _togglingCMSidePage = false; // protect order for await
  toggleCMSidePage() async {
    if (_togglingCMSidePage) return false;
    _togglingCMSidePage = true;
    if (_isShowCMSidePage) {
      _isShowCMSidePage = !_isShowCMSidePage;
      notifyListeners();
      await windowManager.show();
      await windowManager.setSizeAlignment(
          kConnectionManagerWindowSizeClosedChat, Alignment.topRight);
    } else {
      final currentSelectedTab =
          gFFI.serverModel.tabController.state.value.selectedTabInfo;
      final client = parent.target?.serverModel.clients.firstWhereOrNull(
          (client) => client.id.toString() == currentSelectedTab.key);
      if (client != null) {
        client.unreadChatMessageCount.value = 0;
      }
      requestChatInputFocus();
      await windowManager.show();
      await windowManager.setSizeAlignment(
          kConnectionManagerWindowSizeOpenChat, Alignment.topRight);
      _isShowCMSidePage = !_isShowCMSidePage;
      notifyListeners();
    }
    _togglingCMSidePage = false;
  }

  changeCurrentKey(MessageKey key) {
    updateConnIdOfKey(key);
    String? peerName;
    if (key.connId == clientModeID) {
      peerName = parent.target?.ffiModel.pi.username;
    } else {
      peerName = parent.target?.serverModel.clients
          .firstWhereOrNull((client) => client.peerId == key.peerId)
          ?.name;
    }
    if (!_messages.containsKey(key)) {
      final chatUser = ChatUser(
        id: key.peerId,
        firstName: peerName,
      );
      _messages[key] = MessageBody(chatUser, []);
    } else {
      if (peerName != null && peerName.isNotEmpty) {
        _messages[key]?.chatUser.firstName = peerName;
      }
    }
    _currentKey = key;
    notifyListeners();
    mobileClearClientUnread(key.connId);
  }

  receive(int id, String text) async {
    if (text.isEmpty) return;
    final imageChunk = _ImageChunk.tryParse(text);
    if (imageChunk != null) {
      await _receiveImageChunk(id, imageChunk);
      return;
    }
    await _insertIncomingText(id, text);
  }

  Future<void> _receiveImageChunk(int id, _ImageChunk chunk) async {
    if (chunk.total <= 0 || chunk.total > _imageMaxChunks) return;
    final bufferKey = '${id}_${chunk.id}';
    var buffer = _incomingImages[bufferKey];
    if (buffer == null) {
      buffer = _IncomingImage(chunk.total);
      buffer.timer = Timer(const Duration(minutes: 2), () {
        _incomingImages.remove(bufferKey);
      });
      _incomingImages[bufferKey] = buffer;
      if (_incomingImages.length > 16) {
        final oldest = _incomingImages.keys.first;
        _incomingImages.remove(oldest)?.timer?.cancel();
      }
    }
    if (buffer.total != chunk.total) return;
    if (!buffer.add(chunk.index, chunk.data)) return;
    buffer.timer?.cancel();
    _incomingImages.remove(bufferKey);
    Uint8List bytes;
    try {
      bytes = base64Decode(buffer.parts.join());
    } catch (e) {
      debugPrint('Failed to decode chat image: $e');
      return;
    }
    if (bytes.isEmpty) return;
    await _insertIncomingText(id, '', image: bytes);
  }

  Future<void> _insertIncomingText(int id, String text,
      {Uint8List? image}) async {
    final session = parent.target;
    if (session == null) {
      debugPrint("Failed to receive msg, session state is null");
      return;
    }
    if (text.isEmpty && image == null) return;
    if (desktopType == DesktopType.cm) {
      await showCmWindow();
    }
    String? peerId;
    if (id == clientModeID) {
      peerId = session.id;
    } else {
      peerId = session.serverModel.clients
          .firstWhereOrNull((e) => e.id == id)
          ?.peerId;
    }
    if (peerId == null) {
      debugPrint("Failed to receive msg, peerId is null");
      return;
    }

    final messagekey = MessageKey(peerId, id);

    // mobile: first message show overlay icon
    if (!isDesktop && chatIconOverlayEntry == null) {
      showChatIconOverlay();
    }
    // show chat page
    await showChatPage(messagekey);
    late final ChatUser chatUser;
    if (id == clientModeID) {
      chatUser = ChatUser(
        firstName: session.ffiModel.pi.username,
        id: peerId,
      );

      if (isDesktop) {
        if (Get.isRegistered<DesktopTabController>()) {
          DesktopTabController tabController = Get.find<DesktopTabController>();
          var index = tabController.state.value.tabs
              .indexWhere((e) => e.key == session.id);
          final notSelected =
              index >= 0 && tabController.state.value.selected != index;
          // minisized: top and switch tab
          // not minisized: add count
          if (await WindowController.fromWindowId(stateGlobal.windowId)
              .isMinimized()) {
            windowOnTop(stateGlobal.windowId);
            if (notSelected) {
              tabController.jumpTo(index);
            }
          } else {
            if (notSelected) {
              UnreadChatCountState.find(peerId).value += 1;
            }
          }
        }
      }
    } else {
      final client = session.serverModel.clients
          .firstWhereOrNull((client) => client.id == id);
      if (client == null) {
        debugPrint("Failed to receive msg, client is null");
        return;
      }
      if (isDesktop) {
        windowOnTop(null);
        // disable auto jumpTo other tab when hasFocus, and mark unread message
        final currentSelectedTab =
            session.serverModel.tabController.state.value.selectedTabInfo;
        if (currentSelectedTab.key != id.toString() && inputNode.hasFocus) {
          client.unreadChatMessageCount.value += 1;
        } else {
          parent.target?.serverModel.jumpTo(id);
        }
      } else {
        if (HomePage.homeKey.currentState?.isChatPageCurrentTab != true ||
            _currentKey != messagekey) {
          client.unreadChatMessageCount.value += 1;
          mobileUpdateUnreadSum();
        }
      }
      chatUser = ChatUser(id: client.peerId, firstName: client.name);
    }
    insertMessage(
        messagekey,
        ChatMessage(
          // dash_chat_2 skips the text container for empty text, which would
          // also hide the custom image widget. Keep a placeholder text.
          text: text.isEmpty ? '[Image]' : text,
          user: chatUser,
          createdAt: DateTime.now(),
          customProperties: image == null ? null : {'rdImage': image},
        ));
    if (id == clientModeID || _currentKey.peerId.isEmpty) {
      // client or invalid
      _currentKey = messagekey;
      mobileClearClientUnread(messagekey.connId);
    }
    latestReceivedKey = messagekey;
    notifyListeners();
  }

  send(ChatMessage message) {
    String trimmedText = message.text.trim();
    if (trimmedText.isEmpty) {
      return;
    }
    message.text = trimmedText;
    insertMessage(_currentKey, message);
    if (_currentKey.connId == clientModeID && parent.target != null) {
      bind.sessionSendChat(sessionId: sessionId, text: message.text);
    } else {
      bind.cmSendChat(connId: _currentKey.connId, msg: message.text);
    }

    notifyListeners();
    inputNode.requestFocus();
  }

  /// Send images picked from disk. Multiple files are sent one by one.
  Future<void> pickAndSendImages() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: true,
      );
    } catch (e) {
      debugPrint('Failed to pick image: $e');
      return;
    }
    if (result == null) return;
    var failed = false;
    for (final file in result.files) {
      var bytes = file.bytes;
      if ((bytes == null || bytes.isEmpty) && file.path != null) {
        bytes = await chat_local.readLocalFileBytes(file.path!);
      }
      if (bytes == null || bytes.isEmpty) {
        failed = true;
        continue;
      }
      await sendImageBytes(bytes);
    }
    if (failed) {
      showToast(translate('Failed'));
    }
  }

  /// Ask the controlled peer for a screenshot and send it to the chat.
  void sendScreenshotToChat() {
    final session = parent.target;
    if (session == null || _waitingChatScreenshot || !canSendScreenshot) {
      return;
    }
    _waitingChatScreenshot = true;
    final display = session.ffiModel.pi.currentDisplay;
    bind.sessionTakeScreenshot(
        sessionId: sessionId, display: display < 0 ? 0 : display);
    Timer(const Duration(seconds: 20), () {
      if (_waitingChatScreenshot) {
        _waitingChatScreenshot = false;
        showToast(translate('Failed'));
      }
    });
  }

  /// Called when the native side reports a screenshot result.
  Future<void> handleScreenshotForChat(String msg) async {
    final wasWaiting = _waitingChatScreenshot;
    _waitingChatScreenshot = false;
    if (!wasWaiting) return;
    if (msg.isNotEmpty) {
      debugPrint('Take screenshot failed: $msg');
      showToast(translate('Failed'));
      return;
    }
    final path = await chat_local.createScreenshotTempPath();
    if (path == null) {
      showToast(translate('Failed'));
      return;
    }
    final res = await bind.sessionHandleScreenshot(
        sessionId: sessionId, action: '0:$path');
    if (res.isNotEmpty) {
      debugPrint('Save screenshot failed: $res');
      await chat_local.deleteTempFile(path);
      showToast(translate('Failed'));
      return;
    }
    final bytes = await chat_local.readTempFileBytes(path);
    if (bytes == null || bytes.isEmpty) {
      showToast(translate('Failed'));
      return;
    }
    await sendImageBytes(bytes);
  }

  /// Encode an image and send it through the text chat channel in chunks.
  Future<void> sendImageBytes(Uint8List raw) async {
    if (raw.isEmpty) return;
    final data = _prepareImage(raw);
    if (data.isEmpty) return;
    final encoded = base64Encode(data);
    final total = (encoded.length / _imageChunkSize).ceil();
    if (total <= 0 || total > _imageMaxChunks) {
      showToast('${translate('Failed')}: image too large');
      return;
    }
    final key = _currentKey;
    final imageId =
        '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '${(_imageSeq++).toRadixString(36)}';
    // `text` must be non-empty: dash_chat_2 only renders the text container
    // (which hosts the custom image builder) when text is not empty.
    insertMessage(
        key,
        ChatMessage(
          text: '[Image]',
          user: me,
          createdAt: DateTime.now(),
          customProperties: {'rdImage': data},
        ));
    notifyListeners();
    for (var i = 0; i < total; i++) {
      final start = i * _imageChunkSize;
      final end = start + _imageChunkSize < encoded.length
          ? start + _imageChunkSize
          : encoded.length;
      final chunk =
          '[[RDIMG1:$imageId:$i/$total]]${encoded.substring(start, end)}';
      _sendRawText(key, chunk);
      // Yield to the event loop so a big image does not block the UI.
      if (i % 4 == 3) {
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    inputNode.requestFocus();
  }

  void _sendRawText(MessageKey key, String text) {
    if (key.connId == clientModeID && parent.target != null) {
      bind.sessionSendChat(sessionId: sessionId, text: text);
    } else {
      bind.cmSendChat(connId: key.connId, msg: text);
    }
  }

  /// Downscale and re-encode to JPEG to keep chat traffic small.
  Uint8List _prepareImage(Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) return raw;
      var image = decoded;
      const maxDim = 1920;
      if (image.width > maxDim || image.height > maxDim) {
        final ratio =
            maxDim / (image.width > image.height ? image.width : image.height);
        image = img.copyResize(image,
            width: (image.width * ratio).round(),
            height: (image.height * ratio).round());
      }
      var quality = 85;
      var out = img.encodeJpg(image, quality: quality);
      // Keep the encoded image small enough to stay well under the chunk cap.
      while (out.length > 1024 * 1024) {
        if (quality > 40) {
          quality -= 15;
        } else if (image.width > 640 || image.height > 640) {
          image = img.copyResize(image,
              width: (image.width * 0.8).round(),
              height: (image.height * 0.8).round());
          quality = 60;
        } else {
          break;
        }
        out = img.encodeJpg(image, quality: quality);
      }
      return Uint8List.fromList(out);
    } catch (e) {
      debugPrint('Failed to prepare image: $e');
      return raw;
    }
  }

  insertMessage(MessageKey key, ChatMessage message) {
    updateConnIdOfKey(key);
    if (!_messages.containsKey(key)) {
      _messages[key] = MessageBody(message.user, []);
    }
    _messages[key]?.insert(message);
  }

  updateConnIdOfKey(MessageKey key) {
    if (_messages.keys
            .toList()
            .firstWhereOrNull((e) => e == key && e.connId != key.connId) !=
        null) {
      final value = _messages.remove(key);
      if (value != null) {
        _messages[key] = value;
      }
    }
    if (_currentKey == key || _currentKey.peerId.isEmpty) {
      _currentKey = key; // hash != assign
    }
  }

  void mobileUpdateUnreadSum() {
    if (!isMobile) return;
    var sum = 0;
    parent.target?.serverModel.clients
        .map((e) => sum += e.unreadChatMessageCount.value)
        .toList();
    Future.delayed(Duration.zero, () {
      mobileUnreadSum.value = sum;
    });
  }

  void mobileClearClientUnread(int id) {
    if (!isMobile) return;
    final client = parent.target?.serverModel.clients
        .firstWhereOrNull((client) => client.id == id);
    if (client != null) {
      Future.delayed(Duration.zero, () {
        client.unreadChatMessageCount.value = 0;
        mobileUpdateUnreadSum();
      });
    }
  }

  close() {
    hideChatIconOverlay();
    hideChatWindowOverlay();
    notifyListeners();
  }

  resetClientMode() {
    _messages[clientModeID]?.clear();
  }

  void requestChatInputFocus() {
    Timer(Duration(milliseconds: 100), () {
      if (inputNode.hasListeners && inputNode.canRequestFocus) {
        inputNode.requestFocus();
      }
    });
  }

  void _requestChatSoftKeyboard(PointerDownEvent event) {
    if (!isMobile || _softKeyboardRequested.value) return;
    inputNode.context?.visitAncestorElements((element) {
      if (element.widget is! TextField) return true;
      final box = element.findRenderObject();
      if (box is! RenderBox) return false;
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      if (!bounds.contains(event.position)) return false;
      _softKeyboardRequested.value = true;
      _restoreChatInputControl();
      // Reconnect so the platform receives the keyboard type instead of none.
      inputNode.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      scheduleMicrotask(() {
        if (chatWindowOverlayEntry != null && _softKeyboardRequested.value) {
          inputNode.requestFocus();
        }
      });
      return false;
    });
  }

  void _updateChatInputControl() {
    final physicalChatFocused = chatWindowOverlayEntry != null &&
        inputNode.hasFocus &&
        !_softKeyboardRequested.value;
    if (!physicalChatFocused) {
      _restoreChatInputControl();
      return;
    }
    if (_usingPhysicalChatInput) return;
    _usingPhysicalChatInput = true;
    // Keep the platform text-input connection for physical editing, without IME UI.
    TextInput.setInputControl(null);
  }

  void _restoreChatInputControl() {
    if (!_usingPhysicalChatInput) return;
    _usingPhysicalChatInput = false;
    TextInput.restorePlatformInputControl();
  }

  void onVoiceCallWaiting() {
    _voiceCallStatus.value = VoiceCallStatus.waitingForResponse;
  }

  void onVoiceCallStarted() {
    _voiceCallStatus.value = VoiceCallStatus.connected;
    if (isAndroid) {
      parent.target?.invokeMethod("on_voice_call_started");
    }
  }

  void onVoiceCallClosed(String reason) {
    _voiceCallStatus.value = VoiceCallStatus.notStarted;
    if (isAndroid) {
      // We can always invoke "on_voice_call_closed"
      // no matter if the `_voiceCallStatus` was `VoiceCallStatus.notStarted` or not.
      parent.target?.invokeMethod("on_voice_call_closed");
    }
  }

  void onVoiceCallIncoming() {
    if (isConnManager) {
      _voiceCallStatus.value = VoiceCallStatus.incoming;
    }
  }

  void closeVoiceCall() {
    bind.sessionCloseVoiceCall(sessionId: sessionId);
  }
}

enum VoiceCallStatus {
  notStarted,
  waitingForResponse,
  connected,
  // Connection manager only.
  incoming
}
