import 'package:flutter/material.dart';

import '../controllers/chat_controller.dart';
import '../services/chat_storage_service.dart';
import '../services/remote_model_service.dart';
import '../theme/app_colors.dart';

class RemoteBackendSettingsCard extends StatefulWidget {
  const RemoteBackendSettingsCard({
    required this.chatController,
    required this.storage,
    required this.remoteService,
    super.key,
  });

  final ChatController chatController;
  final ChatStorageService storage;
  final RemoteModelService remoteService;

  @override
  State<RemoteBackendSettingsCard> createState() =>
      _RemoteBackendSettingsCardState();
}

class _RemoteBackendSettingsCardState extends State<RemoteBackendSettingsCard> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelIdController;
  final _apiKeyController = TextEditingController();
  final List<String> _availableModels = [];

  bool _hasApiKey = false;
  bool _isSaving = false;
  bool _isLoadingModels = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(
      text: widget.storage.remoteBaseUrl,
    );
    _modelIdController = TextEditingController(
      text: widget.storage.remoteModelId,
    );
    _loadApiKeyStatus();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelIdController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKeyStatus() async {
    try {
      final hasKey = await widget.remoteService.hasApiKey();
      if (mounted) setState(() => _hasApiKey = hasKey);
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _statusMessage = 'Secure storage is unavailable on this device.';
        });
      }
    }
  }

  Future<void> _saveSettings() async {
    setState(() {
      _isSaving = true;
      _statusMessage = null;
    });
    try {
      RemoteModelService.validateBaseUrl(_baseUrlController.text);
      if (_modelIdController.text.trim().isEmpty) {
        throw const FormatException('Enter a remote model ID.');
      }

      final apiKey = _apiKeyController.text;
      if (apiKey.trim().isNotEmpty) {
        await widget.remoteService.saveApiKey(apiKey.trim());
      }
      widget.storage.remoteBaseUrl = _baseUrlController.text.trim();
      widget.storage.remoteModelId = _modelIdController.text.trim();
      widget.chatController.remoteSettingsUpdated();
      _apiKeyController.clear();
      await _loadApiKeyStatus();
      if (mounted) {
        setState(() {
          _statusIsError = false;
          _statusMessage = 'Remote settings saved.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _statusMessage = error.toString().replaceFirst('FormatException: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _loadModels() async {
    setState(() {
      _isLoadingModels = true;
      _statusMessage = null;
      _availableModels.clear();
    });
    try {
      final enteredKey = _apiKeyController.text.trim();
      final models = await widget.remoteService.listModels(
        _baseUrlController.text,
        apiKey: enteredKey.isEmpty ? null : enteredKey,
      );
      if (mounted) {
        setState(() {
          _availableModels
            ..clear()
            ..addAll(models);
          _statusIsError = false;
          _statusMessage = models.isEmpty
              ? 'No models were returned; enter a model ID manually.'
              : 'Select a model or enter its ID manually.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _statusMessage = error.toString().replaceFirst('FormatException: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _isLoadingModels = false);
    }
  }

  Future<void> _clearApiKey() async {
    try {
      await widget.remoteService.clearApiKey();
      if (!mounted) return;
      setState(() {
        _hasApiKey = false;
        _apiKeyController.clear();
        _statusIsError = false;
        _statusMessage = 'Saved API key removed.';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _statusMessage = 'Could not clear the saved API key.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _baseUrlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'OpenAI-compatible base URL',
            hintText: 'https://your-vps.example.com/v1',
            helperText: 'Use the server root or a URL ending in /v1.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _modelIdController,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Model ID',
            hintText: 'Enter the ID accepted by your server',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _apiKeyController,
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Bearer API key',
            hintText: _hasApiKey ? 'Saved securely; blank keeps it' : 'Optional',
            helperText: _hasApiKey
                ? 'A key is saved in platform secure storage.'
                : 'Sent only to the configured remote endpoint.',
          ),
        ),
        if (_hasApiKey)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clearApiKey,
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: const Text('Remove saved key'),
            ),
          ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.orange.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.orange.withValues(alpha: 0.25)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, color: AppColors.orange, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Remote hosts must use HTTPS. HTTP is allowed only for localhost or loopback during local development; it is unencrypted and must not be used for a VPS or an untrusted network.',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _isSaving ? null : _saveSettings,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 17),
              label: const Text('Save remote settings'),
            ),
            OutlinedButton.icon(
              onPressed: _isLoadingModels ? null : _loadModels,
              icon: _isLoadingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('Load /v1/models'),
            ),
          ],
        ),
        if (_availableModels.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Available models',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final model in _availableModels)
                ActionChip(
                  label: Text(model, overflow: TextOverflow.ellipsis),
                  onPressed: () => setState(() => _modelIdController.text = model),
                ),
            ],
          ),
        ],
        if (_statusMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _statusMessage!,
            style: TextStyle(
              color: _statusIsError
                  ? Theme.of(context).colorScheme.error
                  : AppColors.green,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}
