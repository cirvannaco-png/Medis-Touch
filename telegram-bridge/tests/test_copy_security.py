import pytest

from app.application.copy_service import CopyAuthorizationContext, CopyService
from app.domain.brokers import Broker, normalize_broker, supported_brokers
from app.domain.copy import CopyStage


@pytest.fixture
def service():
    return CopyService()


def valid_context(**overrides):
    values = dict(
        broker=Broker.EXNESS,
        symbol="XAUUSD",
        direction="BUY",
        risk_percent=0.5,
        account_equity=1000.0,
        subscription_entitled=True,
        copy_authorized=True,
        portfolio_admitted=True,
    )
    values.update(overrides)
    return CopyAuthorizationContext(**values)


def test_all_supported_brokers_are_normalized():
    assert set(supported_brokers()) == {"exness", "pepperstone", "hfm", "ic_markets", "xm"}
    assert normalize_broker("Pepperdine") is Broker.PEPPERSTONE
    assert normalize_broker("ICMarkets") is Broker.IC_MARKETS


def test_unsupported_broker_fails_closed(service):
    decision = service.authorize(valid_context(broker="unknown-broker"))
    assert not decision.allowed
    assert decision.stage is CopyStage.ELIGIBILITY


def test_expired_subscription_blocks_copy(service):
    decision = service.authorize(valid_context(subscription_entitled=False))
    assert not decision.allowed
    assert decision.stage is CopyStage.SUBSCRIPTION_ENTITLEMENT


def test_copy_authorization_is_separate_from_subscription(service):
    decision = service.authorize(valid_context(copy_authorized=False))
    assert not decision.allowed
    assert decision.stage is CopyStage.COPY_AUTHORIZATION


@pytest.mark.parametrize("risk", [0.09, 2.01, 10.0, -1.0])
def test_risk_bounds_fail_closed(service, risk):
    decision = service.authorize(valid_context(risk_percent=risk))
    assert not decision.allowed
    assert decision.stage is CopyStage.RISK_VALIDATION


def test_zero_equity_fails_closed(service):
    decision = service.authorize(valid_context(account_equity=0))
    assert not decision.allowed
    assert decision.stage is CopyStage.RISK_VALIDATION


def test_portfolio_admission_is_final_pre_execution_gate(service):
    decision = service.authorize(valid_context(portfolio_admitted=False))
    assert not decision.allowed
    assert decision.stage is CopyStage.PORTFOLIO_ADMISSION


def test_valid_request_is_admitted(service):
    decision = service.authorize(valid_context())
    assert decision.allowed
    assert decision.broker is Broker.EXNESS
    assert decision.stage is CopyStage.PORTFOLIO_ADMISSION
