"""Text normalization shared by the fixtures and the scorer.

Reference (AMI) and hypothesis (Whisper) text go through the same steps, so
differences in spelling conventions are not counted as recognition errors:
lowercase; AMI's letter spellings joined ("L_C_D_" is "lcd", as Whisper's
"LCD" or "L.C.D."); punctuation removed except apostrophes; hyphenated words split;
fillers dropped; digits, ordinals, decimals, percentages and currency spelled
out; a short British-to-American map (AMI is transcribed in British English).

`tokenize` works on each word alone, so AMI's one-word-per-entry reference,
the final pass's words and live rows give the same tokens. "And" inside a
spelled number (AMI writes "two hundred and fifty", Whisper "250") needs the
neighbouring words, so `drop_number_and` runs once over a whole stream's
tokens.
"""

from __future__ import annotations

import functools
import re

FILLERS = frozenset(
    {"um", "umm", "uh", "uhh", "er", "erm", "ah", "eh", "hm", "hmm", "mm", "mmm", "mhm", "mm-hmm", "uh-huh"}
)

NEGATIONS = frozenset(
    {"no", "not", "never", "nothing", "nobody", "none", "neither", "nor", "nowhere", "cannot"}
)

BRITISH_TO_AMERICAN = {
    "colour": "color",
    "colours": "colors",
    "coloured": "colored",
    "colourful": "colorful",
    "favourite": "favorite",
    "favourites": "favorites",
    "behaviour": "behavior",
    "centre": "center",
    "centres": "centers",
    "realise": "realize",
    "realised": "realized",
    "organise": "organize",
    "organised": "organized",
    "recognise": "recognize",
    "recognised": "recognized",
    "analyse": "analyze",
    "analysed": "analyzed",
    "programme": "program",
    "programmes": "programs",
    "grey": "gray",
    "metre": "meter",
    "metres": "meters",
    "litre": "liter",
    "labelled": "labeled",
    "cancelled": "canceled",
    "travelling": "traveling",
    "ok": "okay",
}

ONES = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
SCALES = [(1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand"), (100, "hundred")]
ORDINAL_WORDS = {
    "one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
    "nine": "ninth", "twelve": "twelfth",
}
NUMBER_WORDS = frozenset(
    ONES + TENS[2:] + [name for _, name in SCALES]
    + ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
       "eleventh", "twelfth", "twentieth", "thirtieth", "hundredth", "thousandth", "point", "percent"]
)
CURRENCY = {"$": "dollars", "€": "euros", "£": "pounds"}
SCALE_WORDS = frozenset({"hundred", "thousand", "million", "billion"})

_CURRENCY = re.compile(r"([$€£])(\d[\d,]*(?:\.\d+)?)")
_PERCENT = re.compile(r"(\d)%")
_ORDINAL = re.compile(r"^(\d+)(st|nd|rd|th)$")
_DECIMAL = re.compile(r"^(\d+)\.(\d+)$")
_DIGITS_WITH_COMMAS = re.compile(r"^\d{1,3}(,\d{3})+$")
# AMI spells letter sequences with an underscore after each letter: "L_C_D_",
# "T_V_s", "T_V_'s", "anti-R_S_I_". Whisper writes "LCD", "TVs", "TV's", "RSI".
_SPELLED_LETTERS = re.compile(r"\b(?:[a-z]_)+")
_KEEP = re.compile(r"[^a-z0-9'.,\-\s]")


def spell_integer(number: int) -> list[str]:
    """English words for a non-negative integer, without "and"."""
    if number < 20:
        return [ONES[number]]
    if number < 100:
        tens, ones = divmod(number, 10)
        return [TENS[tens]] + ([ONES[ones]] if ones else [])
    for value, name in SCALES:
        if number >= value:
            head, rest = divmod(number, value)
            return spell_integer(head) + [name] + (spell_integer(rest) if rest else [])
    raise AssertionError("unreachable")


def spell_ordinal(number: int) -> list[str]:
    words = spell_integer(number)
    last = words[-1]
    if last in ORDINAL_WORDS:
        words[-1] = ORDINAL_WORDS[last]
    elif last.endswith("y"):
        words[-1] = last[:-1] + "ieth"
    else:
        words[-1] = last + "th"
    return words


def _spell_token(token: str) -> list[str]:
    if _DIGITS_WITH_COMMAS.match(token):
        token = token.replace(",", "")
    if token.isdigit():
        if len(token) > 1 and token.startswith("0"):
            return [ONES[int(digit)] for digit in token]
        return spell_integer(int(token))
    if match := _ORDINAL.match(token):
        return spell_ordinal(int(match.group(1)))
    if match := _DECIMAL.match(token):
        return spell_integer(int(match.group(1))) + ["point"] + [ONES[int(digit)] for digit in match.group(2)]
    return [token]


def _split_word(word: str) -> list[str]:
    """One whitespace-separated word into normalized tokens."""
    word = word.strip(".,'-")
    if not word or word in FILLERS:
        return []
    tokens: list[str] = []
    for part in word.split("-"):
        part = part.strip(".,'")
        if not part or part in FILLERS:
            continue
        for token in _spell_token(part):
            token = token.replace(",", "").replace(".", "")
            if token:
                tokens.append(BRITISH_TO_AMERICAN.get(token, token))
    return tokens


@functools.lru_cache(maxsize=65536)
def _word_tokens(word: str) -> tuple[str, ...]:
    word = word.lower().replace("\u2019", "'").replace("\u2018", "'")
    word = _SPELLED_LETTERS.sub(lambda match: match.group(0).replace("_", ""), word)
    word = _CURRENCY.sub(lambda m: f"{m.group(2)} {CURRENCY[m.group(1)]}", word)
    word = _PERCENT.sub(r"\1 percent", word)
    word = _KEEP.sub(" ", word)
    return tuple(token for part in word.split() for token in _split_word(part))


def tokenize(text: str) -> list[str]:
    """Each whitespace-separated word's tokens, without context from its neighbours."""
    return [token for word in text.split() for token in _word_tokens(word)]


def number_and_mask(tokens: list[str]) -> list[bool]:
    """False for each "and" between a scale word and a number word, as in
    "two hundred and fifty"; True for every token to keep."""
    keep = [True] * len(tokens)
    for index in range(1, len(tokens) - 1):
        if tokens[index] == "and" and tokens[index - 1] in SCALE_WORDS and tokens[index + 1] in NUMBER_WORDS:
            keep[index] = False
    return keep


def drop_number_and(tokens: list[str]) -> list[str]:
    return [token for token, kept in zip(tokens, number_and_mask(tokens)) if kept]


def normalize(text: str) -> list[str]:
    """The tokens a phrase is scored as, read as one stream."""
    return drop_number_and(tokenize(text))


# Number words that are mostly something else in meetings: "this one", "the
# second", "the point".
NOT_CRITICAL_NUMBERS = frozenset({"one", "second", "point"})


def critical_category(word: str) -> str | None:
    """"number" or "negation" for a reference word that must survive, else None.

    Names are not detected here; the clip list names them.
    """
    lowered = word.lower().replace("\u2019", "'").strip(".,!?")
    if any(character.isdigit() for character in lowered):
        return "number"
    tokens = tokenize(word)
    if tokens and all(token in NUMBER_WORDS for token in tokens) and lowered not in NOT_CRITICAL_NUMBERS:
        return "number"
    if lowered in NEGATIONS or lowered.endswith("n't"):
        return "negation"
    return None
