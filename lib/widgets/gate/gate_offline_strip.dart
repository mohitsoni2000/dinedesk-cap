import '../desk_offline_strip.dart';

/// The gate's "no desk" strip. The desk is the only authority on a ticket,
/// so without it nothing is sold or checked in; there is no local fallback.
class GateOfflineStrip extends DeskOfflineStrip {
  const GateOfflineStrip({
    super.key,
    super.message = "Desk unreachable – can't verify entries",
  });
}
