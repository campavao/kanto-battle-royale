# The two-client PvP regression harness (POK-64).
#
# Boots the mod's own relay on 127.0.0.1, launches two LOVE instances with
# separate identities under host_duel.lua / guest_duel.lua, and watches
# both logs: any "PVP FAIL" line fails the run, both "PVP OK" lines pass
# it.  Run from anywhere; needs node and lovec.
#
#   python mods/battle_royale/tests/drivers/pvp/run_pvp.py [scenario] [workdir]
#
# Scenarios: duel (default) -- engage, lockstep fight, KO, spill, play
# again; stall -- the host goes silent at the move menu and the POK-59
# shot clock must forfeit them; freeze -- the host goes silent from the
# battle intro on, and the POK-65 watchdog plus the clock must still end
# it.
#
# Env overrides: LOVEC (lovec.exe path), POKEPORT_IMPORT_ROM, BR_RELAY_PORT.

import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
LOVEC = os.environ.get("LOVEC", r"C:\Program Files\LOVE\lovec.exe")
ROM = os.environ.get("POKEPORT_IMPORT_ROM",
                     r"C:\Users\cam95\Documents\roms\pokemon-red-us.gb")
PORT = os.environ.get("BR_RELAY_PORT", "7790")
TIMEOUT = int(os.environ.get("BR_PVP_TIMEOUT", "900"))
SCENARIOS = {
    "duel": ("host_duel.lua", "guest_duel.lua"),
    "stall": ("host_stall.lua", "guest_stall.lua"),
    "freeze": ("host_freeze.lua", "guest_stall.lua"),
}


def spawn_love(role, driver, workdir, log):
    env = dict(os.environ)
    env.update({
        "POKEPORT_GAME": "red",
        "POKEPORT_IMPORT_ROM": ROM,
        "POKEPORT_IDENTITY": "br-pvp-" + role,
        "POKEPORT_SPEED": "3",
        "POKEPORT_DRIVER": os.path.join(HERE, driver),
        "BR_PVP_DIR": workdir,
        "BR_PVP_ROLE": role,
        "BR_PVP_RELAY": "127.0.0.1:" + PORT,
    })
    return subprocess.Popen([LOVEC, "."], cwd=REPO, env=env,
                            stdout=log, stderr=subprocess.STDOUT)


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def main():
    args = sys.argv[1:]
    scenario = args.pop(0) if args and args[0] in SCENARIOS else "duel"
    workdir = args.pop(0) if args else tempfile.mkdtemp(prefix="br-pvp-")
    os.makedirs(workdir, exist_ok=True)
    for name in ("code.txt", "posted.txt", "host.plog", "guest.plog"):
        p = os.path.join(workdir, name)
        if os.path.exists(p):
            os.remove(p)
    logs = {n: os.path.join(workdir, n + ".log")
            for n in ("relay", "host", "guest")}
    plogs = {n: os.path.join(workdir, n + ".plog")
             for n in ("host", "guest")}

    def voice(role):
        # a client's testimony: its flushed side log plus whatever stdout
        # survived (a terminated LOVE process can eat buffered stdout)
        return read(plogs[role]) + read(logs[role])
    handles, procs = {}, {}
    print("scenario:", scenario)
    print("workdir:", workdir)

    try:
        env = dict(os.environ, PORT=PORT)
        handles["relay"] = open(logs["relay"], "w")
        procs["relay"] = subprocess.Popen(
            ["node", os.path.join(REPO, "mods", "battle_royale", "relay",
                                  "server.js")],
            env=env, stdout=handles["relay"], stderr=subprocess.STDOUT)
        deadline = time.time() + 20
        while time.time() < deadline:
            if "listening" in read(logs["relay"]):
                break
            if procs["relay"].poll() is not None:
                print("FAIL: the relay died on boot")
                print(read(logs["relay"])[-2000:])
                return 1
            time.sleep(0.3)
        else:
            print("FAIL: the relay never listened")
            return 1
        print("relay up on", PORT)

        drivers = SCENARIOS[scenario]
        for role, driver in (("host", drivers[0]), ("guest", drivers[1])):
            handles[role] = open(logs[role], "w")
            procs[role] = spawn_love(role, driver, workdir, handles[role])
        print("both clients launched; watching", TIMEOUT, "s")

        deadline = time.time() + TIMEOUT
        verdict = None
        while time.time() < deadline:
            host, guest = voice("host"), voice("guest")
            if "PVP FAIL" in host or "PVP FAIL" in guest:
                verdict = 1
                break
            if "PVP OK" in host and "PVP OK" in guest:
                verdict = 0
                break
            for role in ("host", "guest"):
                p = procs[role]
                if p.poll() is not None and "PVP OK" not in voice(role):
                    print("FAIL:", role, "exited", p.returncode,
                          "without its OK")
                    verdict = 1
                    break
            if verdict is not None:
                break
            time.sleep(2)
        if verdict is None:
            print("FAIL: timed out after", TIMEOUT, "s")
            verdict = 1

        for name in ("host", "guest"):
            text = voice(name)
            tail = [l for l in text.splitlines() if "PVP" in l][-8:]
            print("--- %s ---" % name)
            for l in tail:
                print(l)
        print("PASS" if verdict == 0 else "FAIL")
        return verdict
    finally:
        for p in procs.values():
            if p.poll() is None:
                p.terminate()
        for h in handles.values():
            try:
                h.close()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
