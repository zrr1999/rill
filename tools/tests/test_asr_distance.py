from hypothesis import given
from hypothesis import strategies as st

from rill_dev.evaluation.asr_quality import characters, distance, normalized


@given(st.text(max_size=24), st.text(max_size=24), st.text(max_size=24))
def test_edit_distance_obeys_metric_laws(left, right, middle):
    result = distance(left, right)
    assert distance(left, left) == 0
    assert result == distance(right, left)
    assert abs(len(left) - len(right)) <= result <= max(len(left), len(right))
    assert result <= distance(left, middle) + distance(middle, right)


@given(st.text(alphabet=st.characters(exclude_characters="\0"), max_size=32))
def test_one_inserted_character_counts_as_one_error(text):
    assert distance(text, text + "\0") == 1
    assert distance(text + "\0", text) == 1
    assert distance(text, "") == len(text)


@given(st.text(max_size=64))
def test_character_normalization_is_stable(text):
    assert normalized(normalized(text)) == normalized(text)
    assert characters(text) == characters(" \t" + text + "\n")


def test_composed_characters_and_significant_punctuation():
    assert characters("cafe\u0301") == characters("café")
    assert distance(characters("不要删除"), characters("删除")) == 2
    assert distance(characters("Rill: 1.0"), characters("Rill: 10")) == 1
