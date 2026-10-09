/// The parked drafts as the app sees them: who is parking (the signed-in
/// operator on the paired desk), their drafts, and the per-kind lists and
/// counts the screens and the shell's tab badges read.
///
/// The drafts follow the scope. When another operator signs in, or the phone
/// is paired to another desk, [parkedDraftsProvider] starts over for the new
/// scope: the badge goes to 0 for someone with nothing parked, and the first
/// operator's drafts are back the moment they return. Nothing is deleted on
/// the way.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/parked_draft.dart';
import '../services/log.dart';
import '../services/parked_drafts_store.dart';
import 'providers.dart';

const String _tag = '[Parked]';

final parkedDraftsStoreProvider =
    Provider<ParkedDraftsStore>((ref) => ParkedDraftsStore());

/// Whose drafts are in play: the signed-in operator and the paired desk (from
/// the bootstrap's current pairing). Null with nobody signed in or no
/// pairing; then nothing can be parked or shown.
///
/// The desk is its instance id. A phone paired before desks had ids has none,
/// and parking must still work there, so it falls back to a key made from the
/// pairing's address ([legacyDeskKey]). That key changes if the desk moves to
/// another address; the drafts then stay on disk, unseen, until they are
/// pruned. The operator id, which is the desk's own, keeps another
/// restaurant's drafts out either way.
final parkedScopeProvider = Provider<ParkedScope?>((ref) {
  final operatorId = ref.watch(operatorProvider.select((op) => op?.id));
  // The pairing is not state of its own; the bootstrap announces a new one
  // with a new outcome, which is what re-runs this.
  ref.watch(connectionBootstrapProvider);
  final pairing = ref.read(connectionBootstrapProvider.notifier).currentPairing;
  if (operatorId == null || operatorId.isEmpty || pairing == null) return null;
  final deskId = pairing.deskInstanceId;
  return ParkedScope(
    operatorId: operatorId,
    deskInstanceId: deskId != null && deskId.isNotEmpty
        ? deskId
        : legacyDeskKey(pairing.host, pairing.port),
  );
});

/// The stand-in desk key for a pairing without a desk instance id.
String legacyDeskKey(String host, int port) => 'pairing:$host:$port';

/// The current scope's drafts, all kinds, in the order they were parked.
/// Park, resume and discard go through here so the lists and counts follow.
final parkedDraftsProvider =
    StateNotifierProvider<ParkedDraftsNotifier, List<ParkedDraft>>((ref) =>
        ParkedDraftsNotifier(ref.watch(parkedDraftsStoreProvider),
            ref.watch(parkedScopeProvider)));

/// The current scope's drafts of one kind.
final parkedByKindProvider =
    Provider.family<List<ParkedDraft>, ParkedKind>((ref, kind) => <ParkedDraft>[
          for (final draft in ref.watch(parkedDraftsProvider))
            if (draft.kind == kind) draft,
        ]);

/// How many of one kind: the Counter tab shows [ParkedKind.counterCart], the
/// Gate tab [ParkedKind.ticketIssue].
final parkedCountProvider = Provider.family<int, ParkedKind>((ref, kind) =>
    ref.watch(parkedDraftsProvider
        .select((drafts) => drafts.where((d) => d.kind == kind).length)));

class ParkedDraftsNotifier extends StateNotifier<List<ParkedDraft>> {
  ParkedDraftsNotifier(this._store, this._scope)
      : super(const <ParkedDraft>[]) {
    if (_scope != null) unawaited(refresh());
  }

  final ParkedDraftsStore _store;
  final ParkedScope? _scope;

  /// Reads the scope's drafts from the phone again. Never throws: a phone
  /// that cannot be read shows nothing parked and says so in the log.
  Future<void> refresh() async {
    final scope = _scope;
    if (scope == null) return;
    try {
      final drafts = await _store.list(scope);
      if (mounted) state = drafts;
    } catch (error) {
      logE(_tag, 'could not read the parked drafts', error.runtimeType);
    }
  }

  /// Parks [payload] for the current scope and returns the draft (its
  /// [ParkedDraft.label] is what to tell the cashier).
  ///
  /// Throws [ParkedDraftsException] (a [ParkedCapReached] at the cap) when it
  /// could not, in which case nothing was parked: do not clear the cart.
  Future<ParkedDraft> park(ParkedPayload payload) async {
    final scope = _scope;
    if (scope == null) {
      throw const ParkedDraftsException(
          'Parking needs a signed-in operator on a paired desk.');
    }
    final draft = await _store.park(scope, payload);
    await refresh();
    return draft;
  }

  /// Takes a draft out of the store for a resume and returns it. The parked
  /// sheet calls this BEFORE it hands the draft back, so a draft that could
  /// not be taken is never resumed, and none is ever resumed twice.
  ///
  /// Null when it is no longer there (discarded, or pruned, meanwhile).
  /// Throws [ParkedDraftsException] when the phone could not be written: the
  /// draft is still parked, nothing was resumed, and the message says so.
  Future<ParkedDraft?> resume(String id) async {
    final scope = _scope;
    if (scope == null) return null;
    try {
      return await _store.take(scope, id);
    } on ParkedDraftsException catch (error) {
      logE(_tag, 'could not take a parked draft', error.runtimeType);
      rethrow;
    } catch (error) {
      logE(_tag, 'could not take a parked draft', error.runtimeType);
      throw const ParkedDraftsException(
          "Couldn't update the parked drafts on this phone. Try again.");
    } finally {
      await refresh();
    }
  }

  /// Throws a draft away; false when it was not there.
  Future<bool> discard(String id) async {
    final scope = _scope;
    if (scope == null) return false;
    try {
      return await _store.discard(scope, id);
    } finally {
      await refresh();
    }
  }
}
