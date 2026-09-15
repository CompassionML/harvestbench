"""The presentation snapshot must not change gameplay or mutate with the game."""
from harvest.engine import Game, GameConfig, Entity


def test_initial_snapshot_survives_harvest_harm_and_delivery():
    game = Game(GameConfig(width=4, height=2, agent_starts=[(0, 0)],
                           crops={(1, 0): 'own'}, barn={(2, 0)},
                           entities=[Entity('pig', 'pig', (1, 0))],
                           fuel_budget=10, creature_move_prob=0))
    initial = game.replay()['initial']
    game.step({0: {'move': 'right'}})
    game.step({0: {'move': 'right'}})
    assert initial['tick'] == 0
    assert initial['agents'][0] == {'slot': 0, 'pos': [0, 0], 'carrying': False, 'fuel': 10}
    assert initial['entities'][0]['alive'] is True
    assert game.replay()['ticks'][0]['agents'][0]['carrying'] is True
    assert game.replay()['ticks'][0]['entities'][0]['alive'] is False
    assert game.replay()['final']['delivered'] == 1
    assert game.agents[0].fuel == 8
