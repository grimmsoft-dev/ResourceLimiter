# Runs inside a hidden editor as Content/Python/init_unreal.py of a throwaway test project (see Test.ps1).
# Reads TestConfig.json next to it: runs its console commands, prints its console variables, then quits.
# Test.ps1 checks the project log for the expected lines.

import json
import os

import unreal

try:
    import TestChecks  # optional plugin-specific helpers for "Eval" expressions
except ImportError:
    TestChecks = None

_frames = 0


def _tick(delta_seconds):
    global _frames
    _frames += 1
    try:
        if _frames == 60:
            for command in _config.get("Commands", []):
                unreal.log("TEST running " + command)
                unreal.SystemLibrary.execute_console_command(None, command)
        elif _frames == 180:
            for name in _config.get("Cvars", []):
                unreal.log("TEST {} = {:g}".format(name, unreal.SystemLibrary.get_console_variable_float_value(name)))
            for expression in _config.get("Eval", []):
                unreal.log("TEST {} = {}".format(expression, eval(expression)))
            unreal.log("TEST done")
            _finish()
    except Exception as error:
        unreal.log_error("TEST failed: {}".format(error))
        _finish()


def _finish():
    unreal.unregister_slate_post_tick_callback(_handle)
    unreal.SystemLibrary.quit_editor()


try:
    with open(os.path.join(os.path.dirname(__file__), "TestConfig.json"), encoding="utf-8-sig") as f:
        _config = json.load(f)
    _handle = unreal.register_slate_post_tick_callback(_tick)
except Exception as error:
    unreal.log_error("TEST failed: {}".format(error))
    unreal.SystemLibrary.quit_editor()
