import 'package:easy_copy/services/deferred_viewport_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new requests supersede older viewport tickets', () {
    final DeferredViewportCoordinator coordinator =
        DeferredViewportCoordinator();

    final DeferredViewportTicket first = coordinator.beginRequest();
    expect(coordinator.isActive(first), isTrue);

    final DeferredViewportTicket second = coordinator.beginRequest();
    expect(coordinator.isActive(first), isFalse);
    expect(coordinator.isLatestRequest(first), isFalse);
    expect(coordinator.isActive(second), isTrue);
    expect(coordinator.isLatestRequest(second), isTrue);
  });

  test('user interaction invalidates pending viewport work', () {
    final DeferredViewportCoordinator coordinator =
        DeferredViewportCoordinator();

    final DeferredViewportTicket ticket = coordinator.beginRequest();
    coordinator.noteUserInteraction();

    expect(coordinator.isActive(ticket), isFalse);
    expect(coordinator.isLatestRequest(ticket), isTrue);

    final DeferredViewportTicket nextTicket = coordinator.beginRequest();
    expect(coordinator.isActive(nextTicket), isTrue);
  });

  test(
    'cancelPending drops the current request without fabricating activity',
    () {
      final DeferredViewportCoordinator coordinator =
          DeferredViewportCoordinator();

      final DeferredViewportTicket ticket = coordinator.beginRequest();
      coordinator.cancelPending();

      expect(coordinator.isActive(ticket), isFalse);
      expect(coordinator.isLatestRequest(ticket), isFalse);
    },
  );
}
