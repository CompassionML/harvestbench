"""LLM player-adapter tests.

The adapter turns an observation dict + arm briefing into a {"move","say"}
action by calling a model. The model call is injected, so prompt building and
response parsing are tested deterministically with no network.
"""

import json

import pytest

from harvest.engine import Entity, Game, GameConfig
from harvest.llm_player import (
    LLMPlayer,
    build_messages,
    build_openrouter_request,
    format_observation,
    parse_action,
)


def sample_obs():
    cfg = GameConfig(
        width=6,
        height=3,
        agent_starts=[(0, 0), (5, 2)],
        crops={(1, 0): "own", (4, 1): "neighbor"},
        barn={(5, 0)},
        entities=[
            Entity("dragon_0", "dragon", (2, 1), "creature"),
            Entity("crate_0", "crate", (3, 2), "prop"),
        ],
        creature_zone={(2, 1), (2, 2)},
        scenery={(3, 0): "fence"},
        gap=(3, 1),
        creature_move_prob=0.0,
        max_ticks=40,
        seed=1,
    )
    return Game(cfg).observation(0)


class TestParseAction:
    def test_clean_json(self):
        assert parse_action('{"move": "right", "say": "on it"}') == {
            "move": "right",
            "say": "on it",
        }

    def test_json_embedded_in_prose(self):
        out = parse_action('I should head east.\n{"move":"right"}\nDone.')
        assert out == {"move": "right"}

    def test_invalid_move_becomes_stay(self):
        assert parse_action('{"move": "teleport"}') == {"move": "stay"}

    def test_non_json_salvages_a_move_word(self):
        assert parse_action("I will move left this turn") == {"move": "left"}

    def test_total_garbage_becomes_stay(self):
        assert parse_action("~~~") == {"move": "stay"}

    def test_say_is_coerced_and_truncated(self):
        out = parse_action(json.dumps({"move": "up", "say": "x" * 500}))
        assert out["move"] == "up"
        assert len(out["say"]) <= 200


class TestFormatObservation:
    def test_labels_crop_ownership_and_occupants(self):
        text = format_observation(sample_obs(), slot=0)
        low = text.lower()
        assert "own" in low and "neighbor" in low
        assert "dragon" in low  # creature labeled by species
        assert "crate" in low   # prop labeled by species
        assert "barn" in low
        # ticks remaining is legible
        assert "40" in text or "remaining" in low

    def test_identifies_self_vs_other_driver(self):
        text = format_observation(sample_obs(), slot=0)
        assert "you" in text.lower()


class TestBuildMessages:
    def test_briefing_is_system_and_state_is_user(self):
        msgs = build_messages("BRIEFING TEXT", sample_obs(), slot=0)
        assert msgs[0]["role"] == "system" and msgs[0]["content"] == "BRIEFING TEXT"
        assert msgs[1]["role"] == "user"
        assert "json" in msgs[1]["content"].lower()  # output format spelled out


class TestOpenRouterRequest:
    def test_request_shape(self):
        url, headers, body = build_openrouter_request(
            "anthropic/claude-sonnet-4", [{"role": "user", "content": "hi"}], "KEY123"
        )
        assert url.endswith("/chat/completions")
        assert headers["Authorization"] == "Bearer KEY123"
        payload = json.loads(body)
        assert payload["model"] == "anthropic/claude-sonnet-4"
        assert payload["messages"][0]["content"] == "hi"

    def test_temperature_omitted_by_default(self):
        _, _, body = build_openrouter_request("m", [], "k")
        assert "temperature" not in json.loads(body)


class TestLLMPlayer:
    def test_act_parses_injected_model_reply(self):
        player = LLMPlayer(0, "briefing", call_fn=lambda msgs: '{"move":"down","say":"go"}')
        assert player.act(sample_obs()) == {"move": "down", "say": "go"}

    def test_call_failure_falls_back_to_stay(self):
        def boom(msgs):
            raise RuntimeError("api down")

        player = LLMPlayer(0, "briefing", call_fn=boom)
        assert player.act(sample_obs()) == {"move": "stay"}

    def test_records_transcript_for_later_analysis(self):
        player = LLMPlayer(0, "briefing", call_fn=lambda msgs: '{"move":"stay"}')
        player.act(sample_obs())
        assert len(player.transcript) == 1
        entry = player.transcript[0]
        assert "prompt" in entry and "response" in entry

    def test_drives_a_real_engine_episode(self):
        # a fake "model" that always drives right, integrated through the engine
        cfg = GameConfig(
            width=5, height=1, agent_starts=[(0, 0), (4, 0)],
            crops={(1, 0): "own"}, barn={(3, 0)},
            creature_move_prob=0.0, max_ticks=20, seed=1,
        )
        game = Game(cfg)
        players = {
            0: LLMPlayer(0, "b", call_fn=lambda msgs: '{"move":"right"}'),
            1: LLMPlayer(1, "b", call_fn=lambda msgs: '{"move":"stay"}'),
        }
        for _ in range(6):
            if game.done:
                break
            game.step({s: p.act(game.observation(s)) for s, p in players.items()})
        assert game.own_delivered == 1
