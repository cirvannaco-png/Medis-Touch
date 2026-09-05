from datetime import datetime, timezone
import pytest
from app.research.validation import walk_forward_windows, holdout
from app.research.promotion import gate, GatePolicy
from app.research.portfolio import PortfolioCoordinator, PositionRisk


def test_walk_forward_has_purge_and_no_overlap():
    w=walk_forward_windows(datetime(2025,1,1,tzinfo=timezone.utc),datetime(2026,1,1,tzinfo=timezone.utc),train_days=30,test_days=10,step_days=10,purge_days=2)
    assert w and w[0].test_start > w[0].train_end


def test_holdout_fails_unless_locked():
    rows=[{"timestamp":datetime(2025,6,1,tzinfo=timezone.utc)}]
    with pytest.raises(PermissionError): holdout(rows,datetime(2025,1,1,tzinfo=timezone.utc),datetime(2025,12,1,tzinfo=timezone.utc),False)


def test_promotion_is_fail_closed():
    d=gate([0.1]*120,[0.2]*120,GatePolicy(min_trades=100),holdout_passed=False)
    assert d.action=="REJECT"


def test_portfolio_atomic_reservation():
    p=PortfolioCoordinator()
    risk=PositionRisk("XAUUSD","BUY",1.0,0.8,{"USD":1.0,"GOLD":1.0})
    assert p.admit("r1",risk)[0]
    assert not p.admit("r1",risk)[0]
    assert p.normalized_heat()==1.0
