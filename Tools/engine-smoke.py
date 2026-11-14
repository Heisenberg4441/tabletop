#!/usr/bin/env python3
import json
import subprocess
import sys

process = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

def call(game, action="state", **parameters):
    request = {"game": game, "action": action, **parameters}
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    response = json.loads(process.stdout.readline())
    if not response.get("ok"):
        raise RuntimeError(f"{game}/{action}: {response}")
    return response

try:
    solitaire = call("solitaire", "new", dealNumber=42)
    assert len(solitaire["state"]["tableau"]) == 7
    call("solitaire", "draw")
    call("solitaire", "undo")

    blackjack = call("blackjack", "new", decks=6)
    call("blackjack", "bet", amount=25)
    call("blackjack", "deal")
    for _ in range(20):
        state = call("blackjack")
        if state.get("needsAdvance"):
            call("blackjack", "advance")
        elif state["phase"] == "insurance":
            call("blackjack", "insurance", take=False)
        elif state["phase"] == "playerTurn":
            call("blackjack", "stand")
        else:
            break

    durak = call("durak", "new", players=2, variant="podkidnoy")
    assert len(durak["state"]["hands"][0]) == 6
    if durak["state"]["actor"] != 0:
        call("durak", "bot")

    poker = call("poker", "new", opponents=2)
    assert len(poker["state"]["players"]) == 3
    for _ in range(20):
        state = call("poker")
        if state["phase"] == "streetComplete":
            call("poker", "advance")
        elif state.get("options", {}).get("seat") == 0:
            action = "check" if state["options"]["canCheck"] else "call"
            call("poker", "play", kind=action)
        elif state["phase"] == "betting":
            call("poker", "bot")
        else:
            break

    pool = call("pool", "new", mode="eightBall")
    assert len(pool["state"]["table"]["balls"]) == 16
    shot = call("pool", "shoot", aim=0, power=0.7)
    assert "replay" in shot and shot["replay"]["tracks"]
    print("Engine smoke passed: all five games and pool replay.")
finally:
    process.kill()
