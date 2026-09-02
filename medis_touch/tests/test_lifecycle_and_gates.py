"""
Covers the parts of handbook section 18 ("Required Test Matrix") that
this repo's new modules actually implement. Items about strategy-engine
output completeness and MQL5 compilation aren't testable here since
those depend on your real detectors / a Windows build environment.
"""

from datetime import datetime, timedelta, timezone

import pytest

from app.calibration import CalibrationGateConfig, evaluate_calibration
from app.copy_trading import (
    AuthorizationError,
    CopyAccount,
    CopyEventStatus,
    CopyTradeEvent,
    Entitlement,
    EntitlementStatus,
    Subscription,
    SubscriptionStatus,
    authorize_and_claim,
    can_copy,
)
from app.execution_validation import (
    RejectionReason,
    SymbolMetadata,
    validate_execution,
    validate_freeze_level,
    validate_stop_distance,
    validate_tick_size,
)
from app.models import (
    OrderType,
    Signal,
    SignalStatus,
    TradeSetup,
    evaluate_signal,
)
from app.payment_webhook import calculate_expiry
from app.payments.base import NormalizedPaymentEvent
from app.payments.smart_glocal import SmartGlocalProvider

NOW = datetime(2026, 1, 1, tzinfo=timezone.utc)


def make_setup(**overrides) -> TradeSetup:
    defaults = {
        "type": OrderType.BUY,
        "entry_top": 3352.0,
        "entry_bottom": 3350.0,
        "invalidation": 3347.0,
        "stop_loss": 3346.0,
        "tp1": 3358.0,
        "tp2": 3364.0,
        "final_tp": 3370.0,
        "confidence": 0.7,
        "creation_time": NOW,
        "expiry_time": NOW + timedelta(hours=4),
    }
    defaults.update(overrides)
    return TradeSetup(**defaults)


def make_signal(**overrides) -> Signal:
    setup = overrides.pop("setup", make_setup())
    return Signal(signal_id="sig-1", setup=setup, **overrides)


# --- section 3/4: invalidation is first-class and distinct from SL ------

def test_invalidation_and_stop_loss_are_independent_fields():
    setup = make_setup()
    assert setup.invalidation != setup.stop_loss
    assert setup.invalidation == 3347.0
    assert setup.stop_loss == 3346.0


def test_setup_rejects_stop_loss_on_wrong_side_for_buy():
    with pytest.raises(ValueError):
        make_setup(stop_loss=3351.0)  # above entry_bottom for a BUY


# --- section 6: lifecycle transitions ------------------------------------

def test_price_crossing_invalidation_transitions_active_to_invalidated():
    signal = make_signal()
    status = evaluate_signal(signal, market_price=3346.5, now=NOW)
    assert status == SignalStatus.INVALIDATED
    assert signal.invalidated_at == NOW


def test_expiry_transitions_active_to_expired():
    signal = make_signal()
    status = evaluate_signal(signal, market_price=3351.0, now=NOW + timedelta(hours=5))
    assert status == SignalStatus.EXPIRED


def test_terminal_status_is_not_re_evaluated():
    signal = make_signal(status=SignalStatus.COMPLETED)
    status = evaluate_signal(signal, market_price=1.0, now=NOW)
    assert status == SignalStatus.COMPLETED


def test_tp_progression():
    signal = make_signal()
    evaluate_signal(signal, market_price=3358.5, now=NOW)
    assert signal.status == SignalStatus.TP1_REACHED
    evaluate_signal(signal, market_price=3364.5, now=NOW)
    assert signal.status == SignalStatus.TP2_REACHED
    evaluate_signal(signal, market_price=3370.5, now=NOW)
    assert signal.status == SignalStatus.COMPLETED


# --- section 8/9: copy authorization gate --------------------------------

def _active_bundle():
    subscription = Subscription(
        subscription_id="sub-1",
        user_id="u1",
        plan="pro",
        provider="smart_glocal",
        provider_reference="ps_1",
        status=SubscriptionStatus.ACTIVE,
        started_at=NOW,
        expires_at=NOW + timedelta(days=30),
    )
    entitlement = Entitlement(
        entitlement_id="ent-1",
        user_id="u1",
        subscription_id="sub-1",
        status=EntitlementStatus.ACTIVE,
        copy_trading=True,
        signal_access=True,
        telegram_access=True,
        valid_from=NOW,
        valid_until=NOW + timedelta(days=30),
    )
    account = CopyAccount(
        account_id="acc-1",
        user_id="u1",
        broker="MT5Broker",
        broker_account_reference="12345",
        enabled=True,
        risk_mode="fixed_lot",
        risk_value=0.1,
    )
    signal = make_signal()
    return subscription, entitlement, account, signal


@pytest.mark.parametrize(
    "field_path,value",
    [
        ("subscription.status", SubscriptionStatus.EXPIRED),
        ("entitlement.copy_trading", False),
        ("account.enabled", False),
    ],
)
def test_can_copy_excludes_on_any_single_failed_condition(field_path, value):
    subscription, entitlement, account, signal = _active_bundle()
    obj_name, attr = field_path.split(".")
    setattr(locals()[obj_name], attr, value)
    assert can_copy(subscription, entitlement, account, signal, NOW) is False


def test_can_copy_excludes_invalidated_signal():
    subscription, entitlement, account, signal = _active_bundle()
    evaluate_signal(signal, market_price=3346.5, now=NOW)  # invalidate it
    assert can_copy(subscription, entitlement, account, signal, NOW) is False


def test_can_copy_excludes_expired_subscription_even_if_status_stale():
    subscription, entitlement, account, signal = _active_bundle()
    subscription.expires_at = NOW - timedelta(days=1)  # status not updated yet
    assert can_copy(subscription, entitlement, account, signal, NOW) is False


def test_can_copy_allows_when_every_condition_holds():
    subscription, entitlement, account, signal = _active_bundle()
    assert can_copy(subscription, entitlement, account, signal, NOW) is True


def test_authorize_and_claim_repeats_the_check_and_rejects_stale_state():
    subscription, entitlement, account, signal = _active_bundle()
    copy_event = CopyTradeEvent(
        copy_id="copy-1",
        signal_id=signal.signal_id,
        user_id="u1",
        account_id="acc-1",
        status=CopyEventStatus.PENDING,
        idempotency_key="idem-1",
        created_at=NOW,
    )
    # Simulate the world changing between poll time and claim time: the
    # signal got invalidated in the gap.
    evaluate_signal(signal, market_price=3346.5, now=NOW)

    with pytest.raises(AuthorizationError):
        authorize_and_claim(
            subscription=subscription,
            entitlement=entitlement,
            account=account,
            signal=signal,
            copy_event=copy_event,
            now=NOW,
        )
    assert copy_event.status == CopyEventStatus.REJECTED


# --- section 15: fail-closed execution validation ------------------------

def test_missing_point_size_rejects_rather_than_passes():
    meta = SymbolMetadata(
        point_size=None,  # the specific bug the handbook calls out
        tick_size=0.00001,
        stops_level_points=50,
        freeze_level_points=10,
        volume_min=0.01,
        volume_max=100.0,
        volume_step=0.01,
        trading_permitted=True,
        session_open=True,
        price_digits=5,
    )
    result = validate_stop_distance(entry_price=1.1000, stop_loss=1.0990, meta=meta)
    assert result.ok is False
    assert result.reason == RejectionReason.MISSING_POINT_SIZE


def test_stop_distance_too_tight_rejects():
    meta = SymbolMetadata(
        point_size=0.00001,
        tick_size=0.00001,
        stops_level_points=50,
        freeze_level_points=10,
        volume_min=0.01,
        volume_max=100.0,
        volume_step=0.01,
        trading_permitted=True,
        session_open=True,
        price_digits=5,
    )
    result = validate_stop_distance(entry_price=1.10000, stop_loss=1.09999, meta=meta)  # 1 point
    assert result.ok is False
    assert result.reason == RejectionReason.STOP_DISTANCE_TOO_TIGHT


# --- section 14: calibration rejects insufficient sample sizes ----------

def test_calibration_rejects_small_sample_matching_handbook_example():
    # "17 trades with a 64.7% win rate is weak evidence of durable edge"
    verdict = evaluate_calibration(
        resolved_trades=17,
        wins=11,  # 64.7%
        config=CalibrationGateConfig(min_resolved_trades=100),
    )
    assert verdict.promotable is False
    assert any("resolved trades" in r for r in verdict.reasons)


def test_calibration_can_pass_with_large_clear_sample():
    verdict = evaluate_calibration(
        resolved_trades=500,
        wins=320,  # 64%
        out_of_sample_resolved_trades=200,
        out_of_sample_wins=125,  # 62.5%
        config=CalibrationGateConfig(min_resolved_trades=100, min_effect_size=0.03),
    )
    assert verdict.promotable is True, verdict.reasons


def test_calibration_default_config_is_constructed_fresh_per_call():
    # Regression test for the B008-style mutable-default-arg fix: two
    # independent calls with no config passed must not share state.
    a = evaluate_calibration(resolved_trades=17, wins=11)
    b = evaluate_calibration(
        resolved_trades=500,
        wins=400,
        out_of_sample_resolved_trades=200,
        out_of_sample_wins=150,
    )
    assert a.promotable is False
    assert b.promotable is True, b.reasons


# --- section 15 (fix): freeze level and tick size are now enforced ------


def _full_meta(**overrides) -> SymbolMetadata:
    defaults = {
        "point_size": 0.00001,
        "tick_size": 0.00001,
        "stops_level_points": 50,
        "freeze_level_points": 100,
        "volume_min": 0.01,
        "volume_max": 100.0,
        "volume_step": 0.01,
        "trading_permitted": True,
        "session_open": True,
        "price_digits": 5,
    }
    defaults.update(overrides)
    return SymbolMetadata(**defaults)


def test_missing_freeze_level_rejects_rather_than_passes():
    meta = _full_meta(freeze_level_points=None)
    result = validate_freeze_level(entry_price=1.10000, stop_loss=1.09000, meta=meta)
    assert result.ok is False
    assert result.reason == RejectionReason.MISSING_FREEZE_LEVEL


def test_freeze_distance_too_tight_rejects():
    # 50 points of distance, but freeze level requires 100.
    meta = _full_meta(freeze_level_points=100)
    result = validate_freeze_level(entry_price=1.10000, stop_loss=1.09950, meta=meta)
    assert result.ok is False
    assert result.reason == RejectionReason.FREEZE_DISTANCE_TOO_TIGHT


def test_missing_tick_size_rejects_rather_than_passes():
    meta = _full_meta(tick_size=None)
    result = validate_tick_size(1.10000, meta)
    assert result.ok is False
    assert result.reason == RejectionReason.MISSING_TICK_SIZE


def test_validate_execution_now_runs_freeze_and_tick_checks():
    # End-to-end: a stop that clears stops_level but sits inside
    # freeze_level must be rejected by validate_execution(), not just
    # by calling validate_freeze_level() directly. This is exactly the
    # gap the handbook flagged (2 of 7 required checks silently absent).
    meta = _full_meta(stops_level_points=10, freeze_level_points=100)
    result = validate_execution(
        entry_price=1.10000,
        stop_loss=1.09950,  # 50 points: clears stops_level(10), fails freeze_level(100)
        volume=1.0,
        meta=meta,
        required_margin=100.0,
        free_margin=1000.0,
    )
    assert result.ok is False
    assert result.reason == RejectionReason.FREEZE_DISTANCE_TOO_TIGHT


# --- section 11/12 (fix): tz-aware expiry, no naive/aware crash ---------


def test_calculate_expiry_is_timezone_aware():
    event = NormalizedPaymentEvent(
        provider="smart_glocal",
        provider_payment_id="p1",
        user_id="u1",
        status="succeeded",
        amount_minor_units=1000,
        currency="USD",
        plan="pro",
        raw={},
    )
    expiry = calculate_expiry(event)
    assert expiry.tzinfo is not None
    # This is the crash this fix prevents: comparing a naive expiry
    # against the tz-aware `now` used everywhere else in the app raises
    # TypeError instead of quietly returning a wrong bool.
    assert expiry > NOW  # would raise TypeError pre-fix if expiry were naive


# --- smart glocal (fix): normalize_event now branches on event_type ----


def _rsa_provider() -> SmartGlocalProvider:
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        NoEncryption,
        PrivateFormat,
        PublicFormat,
    )

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    public_pem = key.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)
    return SmartGlocalProvider(
        project_name="test",
        private_key_pem=private_pem,
        smart_glocal_public_key_pem=public_pem,
    )


def test_ready_to_confirm_event_normalizes_to_pending_even_if_payment_status_says_succeeded():
    # Regression test: before the fix, event_type was read and ignored,
    # so an intermediate ready_to_confirm webhook whose nested payment
    # status happened to already read "succeeded" would normalize to a
    # terminal "succeeded" status and grant a subscription early.
    provider = _rsa_provider()
    payload = {
        "type": "ready_to_confirm",
        "session": {
            "id": "sess_1",
            "acquiring_payments": [
                {
                    "status": "succeeded",
                    "amount_details": {"amount": 1000, "currency": "usd"},
                    "metadata": '{"user_id": "u1", "plan": "pro"}',
                }
            ],
        },
    }
    event = provider.normalize_event(payload)
    assert event.status == "pending"


def test_payment_finished_event_normalizes_to_succeeded():
    provider = _rsa_provider()
    payload = {
        "type": "payment_finished",
        "session": {
            "id": "sess_2",
            "acquiring_payments": [
                {
                    "status": "succeeded",
                    "amount_details": {"amount": 1000, "currency": "usd"},
                    "metadata": '{"user_id": "u1", "plan": "pro"}',
                }
            ],
        },
    }
    event = provider.normalize_event(payload)
    assert event.status == "succeeded"
