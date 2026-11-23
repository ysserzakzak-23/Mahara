"""Tests for the Arabic understanding layer (pure Python, no database)."""
import pytest

from app.utils import arabic_search as ar
from app.utils.arabic_search import SearchDoc

CATALOG = [
    SearchDoc(1, "سباك محترف", "تصليح حنفيات وتسريب مياه وفتح مجاري", "سباكة"),
    SearchDoc(2, "كهربائي منازل", "تمديدات كهربائية وصيانة لوحات", "كهرباء"),
    SearchDoc(3, "صيانة مكيفات", "تعبئة غاز وتنظيف مكيفات سبليت", "تكييف"),
    SearchDoc(4, "شركة تنظيف", "تنظيف شقق ومنازل وسجاد", "تنظيف"),
    SearchDoc(5, "ورشة نجارة", "تفصيل خزائن ومطابخ خشب", "نجارة"),
    SearchDoc(6, "مدرس رياضيات", "دروس خصوصية للتوجيهي", "تعليم"),
    SearchDoc(7, "خدمة تصليح", "أعمال متنوعة", "أخرى", "فني تمديدات صحية"),
    SearchDoc(8, "تصوير أعراس", "تصوير فوتوغرافي وفيديو", "تصوير"),
    SearchDoc(9, "ميكانيكي سيارات", "صيانة محركات وتبديل زيت", "سيارات"),
    SearchDoc(10, "حلاق رجالي", "حلاقة وتشذيب لحية", "تجميل"),
]


def top(query, n=1):
    return [doc_id for doc_id, _ in ar.rank(query, CATALOG)[:n]]


# ------------------------------------------------------------ normalisation
@pytest.mark.parametrize(
    "raw, expected",
    [
        ("سَبّاك", "سباك"),            # diacritics + shadda
        ("أحمد إبراهيم", "احمد ابراهيم"),  # alef variants
        ("حنفية", "حنفيه"),              # taa marbuta
        ("سباااك", "سباك"),              # stretched letters
        ("ســبــاك", "سباك"),             # tatweel
        ("كهرباء", "كهربا"),             # hamza dropped
        ("٠٩١٢", "0912"),               # Arabic-Indic digits
    ],
)
def test_normalize(raw, expected):
    assert ar.normalize(raw) == expected


@pytest.mark.parametrize(
    "a, b",
    [
        ("الحنفية", "حنفية"),
        ("حنفيات", "حنفية"),
        ("للسباك", "سباك"),
        ("كهرباء", "كهربائي"),
        ("المكيفات", "مكيف"),
    ],
)
def test_inflections_share_a_stem(a, b):
    assert ar.stem(ar.normalize(a)) == ar.stem(ar.normalize(b))


def test_stemming_never_goes_below_three_letters():
    assert ar.stem("باب") == "باب"
    assert len(ar.stem("اهم")) == 3


def test_stem_is_idempotent():
    for word in ["الحنفيات", "كهربائي", "سباكة", "مكيفات", "للمعلمين"]:
        once = ar.stem(ar.normalize(word))
        assert ar.stem(once) == once


# ------------------------------------------------------------ query analysis
def test_stopwords_and_filler_are_dropped():
    info = ar.analyze_query("بدي حدا يصلحلي")
    assert "بدي" not in info.stems and "حدا" not in info.stems


def test_a_word_points_to_its_trade():
    assert ar.analyze_query("بدي اصلح حنفية").domains == {"سباكة"}
    assert "تكييف وتبريد" in ar.analyze_query("المكيف عطلان").domains


def test_generic_words_weigh_less():
    info = ar.analyze_query("اصلح حنفية")
    weights = dict(zip(info.stems, info.weights))
    assert weights[ar.stem("حنفيه")] == 1.0
    assert weights[ar.stem("اصلح")] < 1.0


def test_a_typo_still_finds_the_trade():
    assert "سباكة" in ar.analyze_query("سبباك").domains


# ------------------------------------------------------------ ranking
@pytest.mark.parametrize(
    "query, expected_id",
    [
        ("بدي اصلح حنفية", 1),           # the plumber example from the brief
        ("الحنفية عم تنقط", 1),
        ("مياه المطبخ مسدودة", 1),
        ("مجرى مسدود", 1),
        ("سباكه", 1),
        ("سبّاااك", 1),
        ("بدي حدا يصلحلي المكيف", 3),
        ("المكيف عطلان", 3),
        ("ما في كهربا بالبيت", 2),
        ("بدي اغير لمبة", 2),
        ("كهربجي", 2),
        ("بدي اتعلم رياضيات", 6),
        ("استاذ خصوصي", 6),
        ("عندي عرس بدي مصور", 8),
        ("سيارتي بدها تبديل زيت", 9),
        ("قصة شعر", 10),
    ],
)
def test_the_right_service_comes_first(query, expected_id):
    assert top(query) == [expected_id]


def test_a_service_filed_under_others_is_found_by_its_custom_label():
    # service 7 is titled generically but its label says it does plumbing
    assert 7 in top("حنفية", n=3)


def test_unrelated_services_are_not_returned():
    ids = [doc_id for doc_id, _ in ar.rank("بدي اصلح حنفية", CATALOG)]
    assert 3 not in ids and 4 not in ids and 8 not in ids and 10 not in ids


@pytest.mark.parametrize("query", ["", "   ", "بدي حدا", "xyz", "!!!"])
def test_queries_without_meaning_return_nothing(query):
    assert ar.rank(query, CATALOG) == []


def test_scores_are_sorted_and_rounded():
    results = ar.rank("سباك", CATALOG)
    scores = [score for _, score in results]
    assert scores == sorted(scores, reverse=True)
    assert all(score == round(score, 4) for score in scores)


# ------------------------------------------------------------ score
def test_the_score_is_trade_and_words_only():
    assert ar.combine(1.0, 1.0) == pytest.approx(1.0)
    assert ar.combine(0.0, 0.0) == 0.0
    assert ar.combine(1.0, 0.0) == pytest.approx(0.55)


# ------------------------------------------------------------ more trades
TRADES = [
    SearchDoc(1, "سباك محترف", "تصليح حنفيات وتسريب مياه", "سباكة"),
    SearchDoc(2, "حلاق رجالي", "حلاقة وقص شعر وتشذيب لحية", "حلاقة"),
    SearchDoc(3, "صالون تجميل نسائي", "مكياج عرائس وتسريحات وعناية بالبشرة", "تجميل"),
    SearchDoc(4, "مصمم جرافيك", "تصميم شعارات وهوية بصرية وبوسترات", "تصميم"),
    SearchDoc(5, "مترجم معتمد", "ترجمة وثائق ومستندات إنجليزي فرنسي", "ترجمة"),
    SearchDoc(6, "صيانة جوالات", "تغيير شاشات وبطاريات وفورمات", "صيانة"),
    SearchDoc(7, "صيانة لابتوبات", "فورمات وتغيير هارد ورام وتنظيف فيروسات", "صيانة"),
    SearchDoc(8, "فني إلكترونيات", "تصليح دارات وشاشات وأجهزة إلكترونية", "صيانة"),
    SearchDoc(9, "مبرمج مواقع وتطبيقات", "تطوير مواقع ويب وتطبيقات موبايل بفلاتر وبايثون", "برمجة"),
    SearchDoc(10, "إدارة صفحات سوشيال ميديا", "تسويق وإعلانات ممولة وتصميم منشورات", "تسويق"),
    SearchDoc(11, "طبيب أسنان", "تقويم وحشوات وتنظيف أسنان", "طب"),
    SearchDoc(12, "ميكانيكي سيارات", "صيانة محركات وتبديل زيت", "سيارات"),
    SearchDoc(13, "خياطة وتفصيل", "تفصيل فساتين وتعديل ملابس", "خياطة"),
]


@pytest.mark.parametrize(
    "query, expected_id",
    [
        ("بدي حلاق", 2),
        ("قص شعر", 2),
        ("مكياج عروس", 3),
        ("بدي مصمم", 4),
        ("بدي صمم لوغو", 4),
        ("ترجمة وثيقة للفرنسي", 5),
        ("مترجم", 5),
        ("شاشة جوالي انكسرت", 6),
        ("تصليح جوال", 6),
        ("بدي فورمات للابتوب", 7),
        ("لابتوبي بطيء وفيه فيروس", 7),
        ("تصليح لابتوب", 7),
        ("الكترونيات", 8),
        ("تلفزيون خربان", 8),
        ("بدي مبرمج", 9),
        ("تطبيق موبايل", 9),
        ("برمجة", 9),
        ("اعلانات انستغرام", 10),
        ("وجع اسنان", 11),
        ("تبديل زيت", 12),
        ("فستان عرس تفصيل", 13),
    ],
)
def test_more_trades_are_understood(query, expected_id):
    assert ar.rank(query, TRADES)[0][0] == expected_id


def test_neighbouring_trades_show_up_but_rank_lower():
    ids = [doc_id for doc_id, _ in ar.rank("الكترونيات", TRADES)]
    assert ids[0] == 8
    assert 6 in ids and 7 in ids          # phone / laptop repair are electronics too
    assert ids.index(8) < ids.index(6)


def test_an_unrelated_trade_is_not_pulled_in_by_a_neighbour():
    ids = [doc_id for doc_id, _ in ar.rank("بدي حلاق", TRADES)]
    assert 12 not in ids and 9 not in ids and 5 not in ids


def test_a_glued_conjunction_does_not_hide_a_word():
    assert ar.stem(ar.normalize("تسريب")) in ar.stem_variants("وتسريب")
    docs = [SearchDoc(1, "خدمة عامة", "تصليح وتسريب", "أخرى")]
    assert ar.rank("تسريب", docs)


def test_long_plurals_are_not_over_stemmed():
    assert ar.stem(ar.normalize("الكترونيات")) == ar.stem(ar.normalize("الكترونية"))
    assert len(ar.stem(ar.normalize("الكترونيات"))) >= 4


def test_generic_words_do_not_point_to_a_trade():
    assert ar.analyze_query("بدي اصلح").domains == frozenset()
    assert ar.analyze_query("عطلان").domains == frozenset()


# ============================= colloquial verb readings (Arabic step 1)
#
# "بدي حدا يدهنلي الشقة" is how the request is actually typed: an imperfect
# verb with the object pronoun glued on. stem() leaves that as "يدهنل", which
# is in no dictionary, so the search found nothing at all. stem_variants now
# offers the other readings of the same word — without the ي, without the
# pronoun, without either — while stem() itself is unchanged.

COLLOQUIAL_VERBS = [
    # written form, reading that matters, trade it should reach (or None)
    ("يدهنلي", "دهن", "دهان وديكور"),
    ("ينضفلي", "نضف", "تنظيف"),   # "نضف" was added to the dictionary in step 2
    ("يركبلي", "ركب", None),
    ("يصلحلي", "صلح", None),      # "صلح" is generic, never a trade on its own
]


def test_stem_itself_is_unchanged_by_the_new_readings():
    """stem() must still return the plain form - the readings are additions."""
    assert ar.stem("يدهنلي") == "يدهنل"
    assert ar.stem("ينضفلي") == "ينضفل"
    assert ar.stem("يركبلي") == "يركبل"
    assert ar.stem("يصلحلي") == "يصلحل"
    # and the long-standing cases still hold
    assert ar.stem(ar.normalize("الحنفية")) == "حنف"
    assert ar.stem(ar.normalize("سباكة")) == "سباك"
    assert ar.stem(ar.normalize("الكترونيات")) == ar.stem(ar.normalize("الكترونية"))
    assert ar.stem("فك") == "فك"                 # short words are left alone
    assert ar.stem(ar.normalize("يافطة")) == "يافط"   # a real ي is not stripped


def test_every_dictionary_word_keeps_the_stem_it_had():
    """stem() is the index's key: if it moved, the whole dictionary moves."""
    for domain, words in ar.DOMAINS.items():
        for word in words.split():
            token = ar.normalize(word)
            assert ar.stem(token) in ar.stem_variants(token), (word, domain)


def test_a_colloquial_verb_with_an_object_pronoun_reaches_its_trade():
    """The case that returned nothing at all before: "بدي حدا يدهنلي الشقة"."""
    readings = ar.stem_variants(ar.normalize("يدهنلي"))

    assert "دهن" in readings                       # the reading the dictionary knows
    assert "يدهنل" in readings                     # and the plain stem is still there
    assert ar._domains_of_stem("دهن") == frozenset({"دهان وديكور"})

    docs = [
        SearchDoc(1, "معلم دهان", "بدهن الشقة كاملة بسرعة ونظافة", "دهان وطلاء الجدران"),
        SearchDoc(2, "سباك", "تصليح تسريب المياه وتغيير الحنفيات", "سباكة"),
    ]
    results = ar.rank("بدي حدا يدهنلي الشقة", docs)

    assert results, "the painting request still finds nothing"
    assert results[0][0] == 1


@pytest.mark.parametrize("written, reading, trade", COLLOQUIAL_VERBS)
def test_the_colloquial_readings_are_offered_without_inventing_entries(written, reading, trade):
    readings = ar.stem_variants(ar.normalize(written))

    assert reading in readings
    assert ar.stem(written) in readings
    reached = {d for value in readings for d in ar._domains_of_stem(value)}
    if trade is None:
        # No dictionary entry is invented: these readings still reach no trade.
        assert reached == set(), (written, reached)
    else:
        assert trade in reached


def test_a_pronoun_is_read_at_its_full_length():
    """"يدهنلها" drops ـلها, not ـله plus a stray letter."""
    assert "دهن" in ar.stem_variants(ar.normalize("يدهنلها"))
    assert "دهن" in ar.stem_variants(ar.normalize("يدهنلهم"))
    assert "دهن" in ar.stem_variants(ar.normalize("يدهنلك"))


def test_every_added_reading_respects_the_three_letter_floor():
    """Nothing is shortened into a different (or meaningless) word."""
    probes = [
        "يدهنلي", "ينضفلي", "يركبلي", "يصلحلي", "يدهنلها", "يفكلي", "يجيلي",
        "يعملي", "يحلي", "يبرد", "يعلم", "وتسريب", "بصلح", "سباك", "مي", "فك",
    ]
    for probe in probes:
        token = ar.normalize(probe)
        plain = ar.stem(token)
        for reading in ar.stem_variants(token):
            if reading == plain:
                continue                  # the plain stem is kept as it is
            assert len(reading) >= ar._MIN_STEM, (probe, reading)


def test_the_plain_stem_is_always_kept_even_when_it_is_short():
    for probe in ("مي", "فك", "رش", "قص"):
        assert ar.stem(probe) in ar.stem_variants(probe)


def test_the_readings_hold_no_duplicates_and_do_not_change_between_calls():
    for probe in ("يدهنلي", "ينضفلي", "وتسريب", "سباك", "يدهنلها"):
        token = ar.normalize(probe)
        first = ar.stem_variants(token)
        second = ar.stem_variants(token)

        assert isinstance(first, frozenset)          # a set: duplicates impossible
        assert first == second                       # deterministic
        assert len(first) == len(set(first))


def _readings_before_step_one(token):
    """
    What stem_variants returned before the verb readings were added: the
    plain stem plus the one glued-prefix reading (و ب ل ف ك).
    """
    readings = {ar.stem(token)}
    if len(token) >= 4 and token[0] in ar._ATTACHED_PREFIXES:
        rest = ar.stem(token[1:])
        if len(rest) >= ar._MIN_STEM:
            readings.add(rest)
    return readings


def test_no_dictionary_word_stopword_or_generic_word_gains_a_foreign_trade():
    """
    The guard that rejected the other prefixes: stripping ا would read
    "الحمام" as "لحمام" (which fuzzy-matches "لحام"/welding) and ت would read
    "تحديد" as "حديد"/ironwork. With ي and the object pronouns only, no word
    the project already knows picks up a trade that is not its own.

    Only the readings THIS step adds are audited: the older glued-prefix
    reading has its own pre-existing cases (e.g. "كنبات" is also read as
    "نبات"/plants) which are not this step's doing.
    """
    for domain, words in ar.DOMAINS.items():
        for word in words.split():
            token = ar.normalize(word)
            for reading in ar.stem_variants(token) - _readings_before_step_one(token):
                reached = ar._domains_of_stem(reading)
                assert not reached or domain in reached, (word, domain, reading, reached)

    for word in ar.STOPWORDS | ar.GENERIC_WORDS:
        for reading in ar.stem_variants(word) - _readings_before_step_one(word):
            assert not ar._domains_of_stem(reading), (word, reading)


# ================================ the bare cleaning root (Arabic step 2)
#
# "بدي حدا ينضفلي البيت" used to rank a PLUMBER first: the only trade the
# query reached was طبخ وضيافة (because "بيتي"/homemade food stems to "بيت"),
# and a plumber whose text says "بالبيت" matched it. The cleaning reading
# "نضف" that step 1 now produces had nothing to match, because the
# dictionary held "تنضيف" and the stemmer does not strip its ت.

def test_the_cleaning_root_is_reachable_from_the_colloquial_verb():
    readings = ar.stem_variants(ar.normalize("ينضفلي"))

    assert "نضف" in readings                       # produced by step 1
    assert ar._domains_of_stem("نضف") == frozenset({"تنظيف"})


def test_the_cleaning_root_belongs_to_exactly_one_trade():
    """One entry, one trade: no cross-domain mapping was introduced."""
    assert ar._DOMAIN_INDEX["نضف"] == {"تنظيف"}
    assert sum("نضف" in words.split() for words in ar.DOMAINS.values()) == 1


def test_the_cleaning_root_can_only_be_matched_exactly():
    """
    A three-letter entry is never a typo target: the fuzzy lookup runs only
    for stems of four letters or more, and for those the length bound
    (2*min/(a+b)) tops out at 2*3/7 = 0.857, under the 0.86 cutoff. So this
    addition cannot pull a word that merely resembles it into تنظيف.

    (Longer cleaning entries are a different matter and are unchanged:
    "نضيف" already reached تنظيف through "تنضيف" before this step.)
    """
    for length in range(4, 10):
        assert "نضف" not in ar._fuzzy_domain_candidates(length), length
    assert 2.0 * 3 / (4 + 3) < ar._FUZZY_DOMAIN_CUTOFF


def test_no_word_the_project_knows_reads_as_the_new_root():
    """Nothing already in the dictionary, stopwords or generic words becomes
    a cleaning request because of this entry."""
    for domain, words in ar.DOMAINS.items():
        for word in words.split():
            if word == "نضف":
                continue
            assert "نضف" not in ar.stem_variants(ar.normalize(word)), (word, domain)
    for word in ar.STOPWORDS | ar.GENERIC_WORDS:
        assert "نضف" not in ar.stem_variants(word), word


def test_a_colloquial_cleaning_request_ranks_the_cleaner_first():
    """The C3 case, with the plumber that used to win it."""
    docs = [
        SearchDoc(1, "سباك خبرة عشرين سنة",
                  "بصلح كل مشاكل المي وتركيب المجلى والسيفون بالبيت",
                  "سباكة وصيانة تسريبات المياه"),
        SearchDoc(2, "شغالة تنظيف باليومية",
                  "بننضف البيت كامل وغسيل السجاد والكنب وترتيب الغرف",
                  "تنظيف المنازل"),
    ]
    results = ar.rank("بدي حدا ينضفلي البيت", docs)

    assert results, "the cleaning request finds nothing"
    assert results[0][0] == 2, [(doc_id, score) for doc_id, score in results]
    assert "تنظيف" in ar.analyze_query("بدي حدا ينضفلي البيت").domains


def test_the_colloquial_painting_request_still_works():
    """Step 1's case must stay fixed while step 2 is added."""
    docs = [
        SearchDoc(1, "معلم دهان", "بدهن الشقة كاملة بسرعة ونظافة", "دهان وطلاء الجدران"),
        SearchDoc(2, "سباك", "تصليح تسريب المياه وتغيير الحنفيات", "سباكة"),
    ]
    results = ar.rank("بدي حدا يدهنلي الشقة", docs)

    assert results and results[0][0] == 1


def test_the_new_root_does_not_disturb_the_other_trades():
    """
    A cleaning word must not start answering other requests, and the
    requests that already worked must still reach the same trades.
    """
    assert ar.analyze_query("بدي حدا ينضفلي البيت").domains >= frozenset({"تنظيف"})
    assert "تنظيف" not in ar.analyze_query("بدي سباك يصلح تسريب المياه").domains
    assert "تنظيف" not in ar.analyze_query("الكهربا عم تقطع بالبيت").domains
    assert "تنظيف" not in ar.analyze_query("بدي مدرس رياضيات").domains
    assert "سباكة" in ar.analyze_query("بدي سباك يصلح تسريب المياه").domains
    assert "كهرباء" in ar.analyze_query("الكهربا عم تقطع بالبيت").domains
    assert "تعليم ودروس" in ar.analyze_query("بدي مدرس رياضيات").domains


# =================================== the gas root (Arabic step 3)
#
# "في ريحة غاز بالمطبخ" used to rank a KITCHEN-REMOVAL service first: the
# only trade the query reached was نجارة (because "مطبخ" is filed there), and
# the word غاز itself reached nothing — the dictionary held بوتاجاز, whose
# stem is a different key. The root now sits with the appliances that burn
# it (فرن، بوتاجاز، طباخ).

def test_the_gas_root_is_indexed_under_the_appliance_trade():
    assert ar._domains_of_stem("غاز") == frozenset({"صيانة أجهزة منزلية"})


def test_the_gas_root_maps_to_no_other_trade():
    """
    Not تكييف وتبريد, whose gas is فريون (a refrigerant), and not سباكة,
    which carries no gas-piping vocabulary.
    """
    assert ar._DOMAIN_INDEX["غاز"] == {"صيانة أجهزة منزلية"}
    assert "تكييف وتبريد" not in ar._domains_of_stem("غاز")
    assert "سباكة" not in ar._domains_of_stem("غاز")


def test_the_gas_root_occurs_in_exactly_one_dictionary_entry():
    assert sum(
        1 for words in ar.DOMAINS.values() for word in words.split() if word == "غاز"
    ) == 1


def test_no_word_the_project_knows_reads_as_the_gas_root():
    """
    In particular "بوتاجاز" does not: its own reading drops the ب, giving
    "وتاجاز", so the appliance list is not quietly matching غاز twice.
    """
    for domain, words in ar.DOMAINS.items():
        for word in words.split():
            if word == "غاز":
                continue
            assert "غاز" not in ar.stem_variants(ar.normalize(word)), (word, domain)
    for word in ar.STOPWORDS | ar.GENERIC_WORDS:
        assert "غاز" not in ar.stem_variants(word), word


def test_a_gas_smell_ranks_the_gas_technician_first():
    """The F5 case, with the kitchen-removal service that used to win it."""
    docs = [
        SearchDoc(1, "فك وتركيب مطابخ",
                  "تفكيك المطبخ والخزائن ونقلها وتركيبها في المنزل الجديد",
                  "نقل الأثاث"),
        SearchDoc(2, "تصليح أفران وغاز",
                  "صيانة الفرن والبوتاغاز ومعالجة تسريب الغاز والريحة في المطبخ",
                  "صيانة الأجهزة المنزلية"),
    ]
    results = ar.rank("في ريحة غاز بالمطبخ", docs)

    assert results, "the gas request finds nothing"
    assert results[0][0] == 2, [(doc_id, score) for doc_id, score in results]
    assert "صيانة أجهزة منزلية" in ar.analyze_query("في ريحة غاز بالمطبخ").domains


def test_unrelated_requests_never_read_as_the_gas_root():
    """
    No word in a plumbing, electrical, cleaning, tutoring or painting
    request reads as غاز, so this entry cannot pull the appliance trade into
    any of them. (The electrical request reaches صيانة أجهزة منزلية on its
    own through كهربائيات, which predates this step and is left alone.)
    """
    for query, expected in (
        ("بدي سباك يصلح تسريب المياه", "سباكة"),
        ("الكهربا عم تقطع بالبيت", "كهرباء"),
        ("بدي حدا ينضفلي البيت", "تنظيف"),
        ("بدي مدرس رياضيات", "تعليم ودروس"),
        ("بدي حدا يدهنلي الشقة", "دهان وديكور"),
    ):
        for token in ar.tokenize(query):
            assert "غاز" not in ar.stem_variants(token), (query, token)
        assert expected in ar.analyze_query(query).domains, query


def test_the_earlier_steps_are_still_fixed():
    """Step 1 (painting) and step 2 (cleaning) must survive step 3."""
    assert "نضف" in ar.stem_variants(ar.normalize("ينضفلي"))
    assert ar._domains_of_stem("نضف") == frozenset({"تنظيف"})

    cleaning = [
        SearchDoc(1, "سباك خبرة عشرين سنة",
                  "بصلح كل مشاكل المي وتركيب المجلى والسيفون بالبيت",
                  "سباكة وصيانة تسريبات المياه"),
        SearchDoc(2, "شغالة تنظيف باليومية",
                  "بننضف البيت كامل وغسيل السجاد والكنب وترتيب الغرف",
                  "تنظيف المنازل"),
    ]
    assert ar.rank("بدي حدا ينضفلي البيت", cleaning)[0][0] == 2

    painting = [
        SearchDoc(1, "معلم دهان", "بدهن الشقة كاملة بسرعة ونظافة", "دهان وطلاء الجدران"),
        SearchDoc(2, "سباك", "تصليح تسريب المياه وتغيير الحنفيات", "سباكة"),
    ]
    assert ar.rank("بدي حدا يدهنلي الشقة", painting)[0][0] == 1


# ============================ the MSA cleaning spelling (Arabic step 6A)
#
# Step 2 added the colloquial root "نضف" (with ض). Normalisation does not
# unify ض and ظ, so the standard spelling "نظف" was a separate, unindexed
# key and "بدي حدا ينظفلي الشقة" returned nothing at all. Both spellings are
# now listed, each as its own key.

def test_both_cleaning_spellings_point_to_the_cleaning_trade():
    assert ar._domains_of_stem("نظف") == frozenset({"تنظيف"})     # standard ظ
    assert ar._domains_of_stem("نضف") == frozenset({"تنظيف"})     # colloquial ض
    assert ar.normalize("نظف") != ar.normalize("نضف"), "ظ and ض must stay distinct"
    for spelling in ("نظف", "نضف"):
        assert sum(
            1 for words in ar.DOMAINS.values() for word in words.split() if word == spelling
        ) == 1, spelling


def test_the_standard_spelling_is_reachable_from_the_colloquial_verb():
    """Step 1's readings carry both spellings to their own root."""
    assert "نظف" in ar.stem_variants(ar.normalize("ينظفلي"))
    assert "نضف" in ar.stem_variants(ar.normalize("ينضفلي"))


def test_an_msa_cleaning_request_ranks_the_cleaner_first():
    docs = [
        SearchDoc(1, "سباك خبرة عشرين سنة",
                  "بصلح كل مشاكل المي وتركيب المجلى والسيفون بالبيت",
                  "سباكة وصيانة تسريبات المياه"),
        SearchDoc(2, "شركة تنظيف منازل",
                  "جلي البلاط وتنظيف الزجاج والمطابخ والحمامات",
                  "تنظيف المنازل"),
    ]
    results = ar.rank("بدي حدا ينظفلي الشقة", docs)

    assert results, "the MSA cleaning request still finds nothing"
    assert results[0][0] == 2, [(doc_id, score) for doc_id, score in results]
    assert "تنظيف" in ar.analyze_query("بدي حدا ينظفلي الشقة").domains


def test_words_that_only_look_like_the_cleaning_root_are_untouched():
    """
    "ينظم" (to organise) and "نظام" (a system) differ from "نظف" by one
    letter. A three-letter key is only ever matched exactly — the fuzzy
    lookup needs four letters and its length bound tops out at 0.857,
    below the 0.86 cutoff — so none of them becomes a cleaning request.
    """
    for query in ("بدي حدا ينظم غرفة النوم", "بدي مهندس ينظم المخططات", "نظام كهربائي جديد"):
        assert "تنظيف" not in ar.analyze_query(query).domains, query
    for probe in ("ينظم", "نظام", "منظم", "تنظيم"):
        assert "تنظيف" not in ar._domains_of_stem(ar.stem(ar.normalize(probe))), probe
    for length in range(4, 10):
        assert "نظف" not in ar._fuzzy_domain_candidates(length), length


# ============================== the teaching verb (Arabic step 6B)
#
# "بدي حدا يعلم ابني القراءة والكتابة" used to rank an OFFICE CLEANER first.
# The listed word is the conjugation "يعلم", not the root "علم": indexing keys
# a word on stem(normalize(word)), so the entry is the single key "يعلم",
# which this request reaches and "ما بعلم" (= I don't know) does not. The bare
# root would have served both, and measurably demoted the right answer for the
# second — which is why it was rejected.

# The "I don't know" phrasings, with the trade each one must still reach.
NOT_EDUCATION = [
    ("ما بعلم شو المشكلة بالغسالة", "صيانة أجهزة منزلية"),
    ("ما بعلم اذا بدي سباك ولا كهربائي", "سباكة"),
    ("حدا بعلم مين يصلح البراد", "تكييف وتبريد"),
    ("بعلم في تسريب مي بالحمام", "سباكة"),
    ("ما بعلم مين ينضف البيت", "تنظيف"),
    ("بعلم شو السبب بانقطاع الكهربا", "كهرباء"),
    ("بدي علم للسيارة", "سيارات"),
]


def test_the_teaching_verb_is_an_education_term():
    assert ar._domains_of_stem("يعلم") == frozenset({"تعليم ودروس"})
    assert sum(
        1 for words in ar.DOMAINS.values() for word in words.split() if word == "يعلم"
    ) == 1
    # the bare root was deliberately NOT added
    assert "علم" not in ar._DOMAIN_INDEX


def test_a_teaching_request_ranks_a_tutor_first():
    """The E5 case, with the office cleaner that used to win it."""
    docs = [
        SearchDoc(1, "تعقيم وتنظيف مكاتب",
                  "خدمات نظافة دورية للمكاتب والعيادات مع تعقيم الأسطح",
                  "تنظيف المنازل"),
        SearchDoc(2, "تأسيس أطفال",
                  "تأسيس القراءة والكتابة والحساب للصفوف الأولى",
                  "دروس خصوصية"),
    ]
    results = ar.rank("بدي حدا يعلم ابني القراءة والكتابة", docs)

    assert results, "the teaching request finds nothing"
    assert results[0][0] == 2, [(doc_id, score) for doc_id, score in results]
    assert "تعليم ودروس" in ar.analyze_query("بدي حدا يعلم ابني القراءة والكتابة").domains


@pytest.mark.parametrize("query, trade", NOT_EDUCATION)
def test_an_i_dont_know_phrasing_stays_out_of_the_education_domain(query, trade):
    """
    "بعلم" reads as {بعلم, علم}; the reading lookup is exact and neither is
    "يعلم", so none of these requests becomes a tutoring request — and each
    still reaches the trade it is actually about.
    """
    domains = ar.analyze_query(query).domains

    assert "تعليم ودروس" not in domains, query
    assert trade in domains, (query, sorted(domains))


def test_the_bare_root_cannot_reach_the_teaching_entry():
    """What makes the negative cases safe, asserted directly."""
    assert "علم" in ar.stem_variants("بعلم")          # the reading exists ...
    assert "يعلم" not in ar.stem_variants("بعلم")     # ... but it is not the key
    assert ar._domains_of_stem("بعلم") == frozenset()
    assert ar._domains_of_stem("علم") == frozenset()
    # and the earlier steps are untouched
    assert ar._domains_of_stem("نضف") == frozenset({"تنظيف"})
    assert ar._domains_of_stem("نظف") == frozenset({"تنظيف"})
    assert ar._domains_of_stem("غاز") == frozenset({"صيانة أجهزة منزلية"})
    assert "دهن" in ar.stem_variants(ar.normalize("يدهنلي"))
