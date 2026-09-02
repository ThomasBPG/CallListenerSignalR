from replay_call import chunk_words


def test_chunk_words_splits_into_groups_of_ten():
    text = " ".join(f"word{i}" for i in range(25))
    chunks = chunk_words(text, size=10)
    assert len(chunks) == 3
    assert chunks[0] == " ".join(f"word{i}" for i in range(10))
    assert chunks[2] == "word20 word21 word22 word23 word24"


def test_chunk_words_handles_exact_multiple():
    text = " ".join(f"word{i}" for i in range(20))
    chunks = chunk_words(text, size=10)
    assert len(chunks) == 2
