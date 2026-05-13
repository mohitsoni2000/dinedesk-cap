// Customer Search / Create Sheet — search existing customers or create a new
// one to attach to the current order.
//
// Invoked from order_review_screen when the operator wants to tag a customer.
// Returns the selected/created customer map, or null if dismissed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/liquid_glass_surface.dart';

class CustomerSheet {
  /// Opens the customer search/create bottom sheet.
  /// Returns the selected or newly created customer map, or null if dismissed.
  static Future<Map<String, dynamic>?> show(BuildContext context) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => const _CustomerSheet(),
    );
  }
}

class _CustomerSheet extends ConsumerStatefulWidget {
  const _CustomerSheet();
  @override
  ConsumerState<_CustomerSheet> createState() => _CustomerSheetState();
}

class _CustomerSheetState extends ConsumerState<_CustomerSheet> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  bool _showCreate = false;

  // Create form controllers.
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  bool _creating = false;
  String? _createError;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _results = [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _performSearch(query.trim());
    });
  }

  void _performSearch(String query) {
    final socket = ref.read(socketServiceProvider);
    socket.emit('customer:search', {'query': query}, onAck: (response) {
      if (!mounted) return;
      final list = response['customers'];
      setState(() {
        _searching = false;
        _results = list is List
            ? list.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : [];
      });
    });
  }

  void _selectCustomer(Map<String, dynamic> customer) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(customer);
  }

  void _toggleCreateForm() {
    HapticFeedback.selectionClick();
    setState(() {
      _showCreate = !_showCreate;
      _createError = null;
    });
  }

  void _submitCreate() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _createError = 'Name is required');
      return;
    }

    setState(() {
      _creating = true;
      _createError = null;
    });
    HapticFeedback.mediumImpact();

    final data = <String, dynamic>{
      'name': name,
      if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
      if (_email.text.trim().isNotEmpty) 'email': _email.text.trim(),
      if (_address.text.trim().isNotEmpty) 'address': _address.text.trim(),
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
    };

    final socket = ref.read(socketServiceProvider);
    socket.emit('customer:create', data, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        setState(() {
          _creating = false;
          _createError = response['message']?.toString() ?? 'Creation failed';
        });
        return;
      }
      // Return the created customer — server wraps it in 'customer' key.
      final customer = response['customer'] as Map?;
      if (customer != null) {
        Navigator.of(context).pop(Map<String, dynamic>.from(customer));
      } else {
        // Fallback: treat whole response as customer data (older server versions).
        Navigator.of(context).pop(Map<String, dynamic>.from(response));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => LiquidGlassSurface(
        blur: 30,
        thickness: 14,
        borderRadius: const BorderRadius.vertical(top: AppRadii.lg),
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.ink30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Find Customer', style: AppTypography.title),
                  const SizedBox(height: 4),
                  const Text('Search by name or phone',
                      style: AppTypography.caption),
                  const SizedBox(height: 12),
                  // Search bar.
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.55),
                      borderRadius: const BorderRadius.all(AppRadii.sm),
                      border: Border.all(color: AppColors.ink10),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: TextField(
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Name or phone number...',
                        icon:
                            Icon(Icons.search, color: AppColors.ink50, size: 20),
                        isDense: true,
                      ),
                      onChanged: _onSearchChanged,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.ink10),
            Expanded(
              child: _showCreate
                  ? _buildCreateForm(scroll)
                  : _buildSearchResults(scroll),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.lg + MediaQuery.of(context).viewPadding.bottom,
              ),
              child: _showCreate
                  ? Row(
                      children: [
                        Expanded(
                          child: LiquidSecondaryButton(
                            label: 'Back',
                            leadingIcon: Icons.arrow_back,
                            onPressed: _toggleCreateForm,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LiquidPrimaryButton(
                            label: 'Save',
                            fullWidth: true,
                            leadingIcon: Icons.check,
                            onPressed: _creating ? null : _submitCreate,
                          ),
                        ),
                      ],
                    )
                  : LiquidSecondaryButton(
                      label: 'Create New Customer',
                      leadingIcon: Icons.person_add_outlined,
                      onPressed: _toggleCreateForm,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults(ScrollController scroll) {
    if (_searching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.terra500,
            ),
          ),
        ),
      );
    }

    if (_search.text.trim().isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_search_outlined,
                  color: AppColors.ink30, size: 40),
              SizedBox(height: 12),
              Text('Search for a customer', style: AppTypography.caption),
            ],
          ),
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off, color: AppColors.ink30, size: 40),
              const SizedBox(height: 12),
              Text('No results for "${_search.text.trim()}"',
                  style: AppTypography.caption),
              const SizedBox(height: 4),
              const Text('Try a different search or create a new customer',
                  style: AppTypography.caption),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      controller: scroll,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final c = _results[i];
        final name = c['name']?.toString() ?? 'Unknown';
        final phone = c['phone']?.toString() ?? '';
        final visits = c['visit_count'] ?? c['visits'] ?? 0;
        final credit = (c['credit_balance'] ?? c['credit'] ?? 0).toDouble();

        return AppCard(
          onTap: () => _selectCustomer(c),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.terra500.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: AppTypography.title
                        .copyWith(color: AppColors.terra600),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: AppTypography.bodyMd
                            .copyWith(fontWeight: FontWeight.w600)),
                    if (phone.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(phone, style: AppTypography.caption),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('$visits visits',
                      style: AppTypography.caption
                          .copyWith(fontWeight: FontWeight.w600)),
                  if (credit > 0) ...[
                    const SizedBox(height: 2),
                    Text('Credit: ${credit.toStringAsFixed(0)}',
                        style: AppTypography.caption
                            .copyWith(color: AppColors.success)),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCreateForm(ScrollController scroll) {
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      children: [
        const Text('New Customer', style: AppTypography.title),
        const SizedBox(height: 4),
        const Text('Fill in the details to create a customer',
            style: AppTypography.caption),
        const SizedBox(height: 16),
        _FormField(controller: _name, label: 'Name *', icon: Icons.person_outline),
        const SizedBox(height: 12),
        _FormField(
            controller: _phone,
            label: 'Phone',
            icon: Icons.phone_outlined,
            keyboardType: TextInputType.phone),
        const SizedBox(height: 12),
        _FormField(
            controller: _email,
            label: 'Email',
            icon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 12),
        _FormField(
            controller: _address,
            label: 'Address',
            icon: Icons.location_on_outlined),
        const SizedBox(height: 12),
        _FormField(
            controller: _notes,
            label: 'Notes',
            icon: Icons.sticky_note_2_outlined,
            maxLines: 2),
        if (_createError != null) ...[
          const SizedBox(height: 12),
          Text(_createError!,
              style: AppTypography.caption.copyWith(color: AppColors.danger)),
        ],
        if (_creating) ...[
          const SizedBox(height: 16),
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.terra500),
            ),
          ),
        ],
      ],
    );
  }
}

class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType keyboardType;
  final int maxLines;

  const _FormField({
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType = TextInputType.text,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: const BorderRadius.all(AppRadii.sm),
        border: Border.all(color: AppColors.ink10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: label,
          icon: Icon(icon, color: AppColors.ink50, size: 20),
          isDense: true,
        ),
      ),
    );
  }
}
