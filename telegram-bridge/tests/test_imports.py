"""Deployment smoke tests for the Render application boundary."""


def test_application_factory_imports():
    from app.main import create_app

    app = create_app()
    assert app.title == "Medis Touch Telegram Bridge"


def test_deployment_state_machine_is_local_to_bridge():
    from app.deployment import DeploymentState, transition

    assert (
        transition(DeploymentState.SCHEDULED, DeploymentState.EA_VALIDATED)
        is DeploymentState.EA_VALIDATED
    )
    assert (
        transition(DeploymentState.EA_VALIDATED, DeploymentState.EA_ACKNOWLEDGED)
        is DeploymentState.EA_ACKNOWLEDGED
    )
    assert (
        transition(DeploymentState.EA_ACKNOWLEDGED, DeploymentState.ACTIVE)
        is DeploymentState.ACTIVE
    )
