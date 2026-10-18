# SPDX-License-Identifier: MIT
# Copyright (c) Steppe contributors
"""Native regression runner; never launches Wine or the game."""
import os
from pathlib import Path
import subprocess

build = Path("build").resolve()
lib = str(build / "libglfix.dylib")
base_env = {k: v for k, v in os.environ.items() if not k.startswith("GLFIX_")}
base_env.pop("DYLD_INSERT_LIBRARIES", None)
passed = failed = skipped = 0

def run(name, command, expected=0, contains=None, env=None):
    global passed, failed
    result = subprocess.run(command, env=base_env | (env or {}), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
    (build / (name + ".log")).write_text(result.stdout)
    ok = result.returncode == expected and (contains is None or contains in result.stdout)
    print(("PASS " if ok else "FAIL ") + name + f" (exit {result.returncode})")
    if ok:
        passed += 1
    else:
        failed += 1
        print(result.stdout[-3000:])
    return result

run("frametimes_off", [str(build / "test_frametimes")], contains="FRAMETIMES_OFF_PASS")
prefix = build / "frames"
for p in build.glob("frames.*"):
    p.unlink()
run("frametimes_threads_fork", [str(build / "test_frametimes")],
    contains="FRAMETIMES_PASS", env={"GLFIX_FRAMETIMES": str(prefix)})
files = list(build.glob("frames.*"))
if len(files) != 1 or len(files[0].read_text().splitlines()) != 4001:
    print("FAIL frametimes exit flush")
    failed += 1
else:
    print("PASS frametimes exit flush: 4001 events")
    passed += 1
run("frametimes_open_failure", [str(build / "test_frametimes")],
    contains="FRAMETIMES_OPEN_FAILURE_SAFE",
    env={"GLFIX_FRAMETIMES": str(build / "missing" / "frames")})
explicit_log = build / "explicit.log"
explicit_log.unlink(missing_ok=True)
run("explicit_log", [str(build / "test_child")], env={"DYLD_INSERT_LIBRARIES": lib,
    "GLFIX_LOG": str(explicit_log)}, contains="PASS explicit log CLOEXEC")
if explicit_log.exists() and "[glfix] loaded" in explicit_log.read_text():
    passed += 1
    print("PASS explicit log opt-in")
else:
    failed += 1
    print("FAIL explicit log opt-in")
spawner, child, dummy = map(lambda n: str(build / n), ["test_spawner", "test_child", "libdummy.dylib"])
for remap in [None, "1", "2"]:
    for mode in ["clean", "merge", "dup"]:
        env = {"DYLD_INSERT_LIBRARIES": lib}
        if remap:
            env["GLFIX_REMAP"] = remap
        expected = ("(null)" if remap is None else lib) if mode == "clean" else dummy + (":" + lib if remap or mode == "dup" else "")
        run(f"propagation_{remap}_{mode}", [spawner, child, mode, dummy],
            contains="RC=0 CHILD_DYLD=" + expected, env=env)
# These checks replace CGLSetCurrentContext entirely; they need no GL context.
caller_env = {"DYLD_INSERT_LIBRARIES": str(build / "libtest_winemac_caller.dylib")}
run("winemac_caller", [str(build / "test_winemac_caller"), str(build / "winemac.so")],
    contains="WINEMAC_CALLER_PASS", env=caller_env)
run("winemac_tailcall_control", [str(build / "test_winemac_caller"), str(build / "tailcall" / "winemac.so")],
    expected=1, contains="WINEMAC_CALLER_FAIL: shim return address lost", env=caller_env)
probe = subprocess.run([str(build / "test_gl_context")], env=base_env, capture_output=True, text=True)
if probe.returncode == 77:
    print(probe.stdout.strip())
    skipped = 7
    print("SKIP GL: baseline, direct, dlsym, program restore, share groups, pbuffer, reference comparison")
elif probe.returncode:
    print("FAIL GL context probe")
    failed += 1
else:
    run("baseline", [str(build / "glfix_validate")], expected=1, contains="1/42 bones correct")
    for mode in ["direct", "dlsym"]:
        env = {"DYLD_INSERT_LIBRARIES": lib, "GLFIX_REMAP": "1"}
        if mode == "dlsym":
            env["GLFIX_VALIDATE_DLSYM"] = "1"
        run("uniform_" + mode, [str(build / "glfix_validate")], contains="42/42 bones correct", env=env)
    for name in ["test_prog_uniform", "test_share_group", "test_pbemu"]:
        run(name, [str(build / name)], env={"DYLD_INSERT_LIBRARIES": lib, "GLFIX_REMAP": "2" if name == "test_pbemu" else "1"})
    reference = os.environ.get("GLFIX_REFERENCE_DYLIB")
    if reference:
        for name in ["test_pbemu", "glfix_validate"]:
            old = run("reference_" + name, [str(build / name)], expected=0 if name == "test_pbemu" else 1,
                      env={"DYLD_INSERT_LIBRARIES": reference, "GLFIX_REMAP": "2"})
            new = run("production_" + name, [str(build / name)], expected=old.returncode,
                      env={"DYLD_INSERT_LIBRARIES": lib, "GLFIX_REMAP": "2"})
            if new.stdout != old.stdout:
                print("FAIL reference output differs: " + name)
                failed += 1
            else:
                print("PASS reference output identical: " + name)
                passed += 1
    else:
        print("SKIP reference comparison: GLFIX_REFERENCE_DYLIB unset")
        skipped += 1
print(f"RESULT: {passed} passed, {failed} failed, {skipped} skipped")
raise SystemExit(bool(failed))
