# Helpers for TestConfig.json "Eval" expressions; runs inside the test editor.

import ctypes
from ctypes import wintypes


class _CpuRateControl(ctypes.Structure):
    _fields_ = [("ControlFlags", wintypes.DWORD), ("CpuRate", wintypes.DWORD)]


def job_cpu_rate():
    """CPU-rate control of the editor's own (innermost) job object, as Windows reports it."""
    info = _CpuRateControl()
    returned = wintypes.DWORD()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    if not kernel32.QueryInformationJobObject(None, 15, ctypes.byref(info), ctypes.sizeof(info), ctypes.byref(returned)):
        return "error {}".format(ctypes.get_last_error())
    return "flags={} rate={}".format(info.ControlFlags, info.CpuRate)
