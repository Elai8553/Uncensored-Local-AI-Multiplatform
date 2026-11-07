import 'dart:async';

import 'package:get/get.dart';

import '../models/chat_model.dart';
import '../models/message_model.dart';
import '../services/llm_service.dart';
import '../services/chat_storage_service.dart';
import '../services/remote_model_service.dart';

class ChatController extends GetxController {
  final LlmService _llm = Get.find<LlmService>();
  final ChatStorageService _storage = Get.find<ChatStorageService>();
  final RemoteModelService _remote = Get.find<RemoteModelService>();

  final chats = <ChatModel>[].obs;
  final activeChatId = RxnString();
  final isGenerating = false.obs;
  final streamedResponse = ''.obs;
  final temperature = 0.7.obs;
  final systemPrompt = ''.obs;
  final chatBackend = 'local'.obs;
  final remoteSettingsRevision = 0.obs;

  bool _cancelRequested = false;

  bool get isRemoteBackend => chatBackend.value == 'remote';
  String get remoteBaseUrl => _storage.remoteBaseUrl;
  String get remoteModelId => _storage.remoteModelId;

  void setChatBackend(String value) {
    chatBackend.value = value == 'remote' ? 'remote' : 'local';
    _storage.chatBackend = chatBackend.value;
  }

  void remoteSettingsUpdated() => remoteSettingsRevision.value++;

  @override
  void onInit() {
    super.onInit();
    _loadChats();
    chatBackend.value = _storage.chatBackend;
    temperature.value = _storage.defaultTemperature;
    systemPrompt.value = _storage.globalSystemPrompt;
  }

  void _loadChats() {
    chats.value = _storage.getAllChats();
  }

  ChatModel? get activeChat {
    if (activeChatId.value == null) return null;
    try {
      return chats.firstWhere((c) => c.id == activeChatId.value);
    } catch (_) {
      return null;
    }
  }

  /// Create a new chat and switch to it.
  void newChat() {
    final chat = ChatModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      systemPrompt: systemPrompt.value,
    );
    chats.insert(0, chat);
    _storage.saveChat(chat);
    activeChatId.value = chat.id;
  }

  /// Switch to an existing chat.
  void switchChat(String id) {
    activeChatId.value = id;
    final chat = activeChat;
    if (chat != null) {
      systemPrompt.value = chat.systemPrompt;
    }
  }

  /// Delete a chat.
  void deleteChat(String id) {
    chats.removeWhere((c) => c.id == id);
    _storage.deleteChat(id);
    if (activeChatId.value == id) {
      activeChatId.value = chats.isNotEmpty ? chats.first.id : null;
    }
  }

  /// Send a user message and stream AI response.
  Future<void> sendMessage(String text, {String? modelFilename}) async {
    if (isGenerating.value || text.trim().isEmpty) return;
    final chat = activeChat;
    if (chat == null) return;

    // Add user message
    final userMsg = MessageModel(role: MessageRole.user, content: text.trim());
    chat.messages.add(userMsg);
    chat.autoTitle();
    chat.updatedAt = DateTime.now();

    // Record the selected inference backend on the first turn.
    if (chat.modelId.isEmpty) {
      if (isRemoteBackend && remoteModelId.trim().isNotEmpty) {
        chat.modelId = 'remote:${remoteModelId.trim()}';
      } else if (modelFilename != null) {
        chat.modelId = modelFilename;
      }
    }

    _storage.saveChat(chat);
    chats.refresh();

    // Build message history for LLM
    final history = chat.messages
        .where((m) => !m.isSystem)
        .map((m) => m.toLlamaMessage())
        .toList();

    // Start generation through the selected backend without changing local history.
    _cancelRequested = false;
    isGenerating.value = true;
    streamedResponse.value = '';

    final aiMsg = MessageModel(role: MessageRole.assistant, content: '');
    chat.messages.add(aiMsg);
    chats.refresh();

    try {
      final prompt = chat.systemPrompt.isNotEmpty
          ? chat.systemPrompt
          : systemPrompt.value;
      final stream = isRemoteBackend
          ? _remote.generate(
              baseUrl: remoteBaseUrl,
              modelId: remoteModelId,
              messages: history,
              systemPrompt: prompt,
              temperature: temperature.value,
            )
          : _llm.generate(
              messages: history,
              systemPrompt: prompt,
              temperature: temperature.value,
            );

      await for (final token in stream) {
        streamedResponse.value += token;
        aiMsg.content = streamedResponse.value;
        // Throttle UI refreshes
        chats.refresh();
      }
    } catch (e) {
      if (!_cancelRequested) {
        aiMsg.content = aiMsg.content.isEmpty
            ? 'Error: $e'
            : '${aiMsg.content}\n\nGeneration interrupted: $e';
      }
    } finally {
      // Clean up any trailing stop tokens or whitespace
      aiMsg.content = aiMsg.content
          .replaceAll(RegExp(
            r'<\|end\|>|<\|eot_id\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>'
            r'|<end_of_turn>|<start_of_turn>|<\|assistant\|>|<\|user\|>|<\|system\|>'
            r'|<\|pad\|>|</s>|<s>|\[INST\]|\[/INST\]|\[end\]'
          ), '')
          .trim();
      isGenerating.value = false;
      _cancelRequested = false;
      streamedResponse.value = '';
      chat.updatedAt = DateTime.now();
      _storage.saveChat(chat);
      chats.refresh();
    }
  }

  /// Stop the active remote request or local inference without discarding history.
  Future<void> stopGeneration() async {
    if (!isGenerating.value) return;
    _cancelRequested = true;
    if (isRemoteBackend) {
      _remote.cancelGeneration();
    } else {
      await _llm.stopGeneration();
    }
  }

  /// Update the system prompt for the active chat.
  void updateSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    final chat = activeChat;
    if (chat != null) {
      chat.systemPrompt = prompt;
      _storage.saveChat(chat);
    }
  }

  /// Set and persist the global system prompt.
  void setGlobalSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    _storage.globalSystemPrompt = prompt;
  }

  /// Clear global system prompt.
  void clearGlobalSystemPrompt() {
    systemPrompt.value = '';
    _storage.globalSystemPrompt = '';
  }

  void updateTemperature(double temp) {
    temperature.value = temp;
    _storage.defaultTemperature = temp;
  }

  @override
  void onClose() {
    if (isGenerating.value) {
      _cancelRequested = true;
      if (isRemoteBackend) {
        _remote.cancelGeneration();
      } else {
        unawaited(_llm.stopGeneration());
      }
    }
    super.onClose();
  }
}
