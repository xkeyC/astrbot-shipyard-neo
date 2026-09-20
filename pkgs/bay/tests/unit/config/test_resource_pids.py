"""Fork addition: the pids limit comes from the profile, not a constant."""

from app.config import ResourceSpec


def test_default_leaves_room_for_many_agent_shell_sessions():
    # Each exec_command session is a tmux pane, a shell and the command, so a
    # sandbox hosting a hundred of them needs far more than a person would.
    assert ResourceSpec().pids >= 1024


def test_a_profile_can_set_its_own_limit():
    assert ResourceSpec(cpus=2.0, memory="4g", pids=2048).pids == 2048
