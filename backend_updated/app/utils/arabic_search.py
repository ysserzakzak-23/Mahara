"""
Arabic keyword understanding: normalising, stemming, a trade knowledge base
and keyword ranking. Pure Python: no database, no web framework, no model.

It ranks the exchange-request search (exchange_service) and decides whether
two «أخرى» labels name the same trade (`labels_equivalent`). The service
search does NOT use it to rank — that is meaning alone, see
smart_search_service.py; it only borrows the tokenizer and stemmer here.

What it does
------------
1. Normalises Arabic the way people really type it: drops diacritics and
   tatweel, unifies alef/yaa/taa-marbuta/hamza variants, converts Arabic-Indic
   digits and squeezes stretched letters ("سباااك" -> "سباك").
2. Light stemming that is *idempotent* (the same word with or without ال, with
   a plural/feminine ending, etc. ends up as the same stem).
3. A hand-written knowledge base (`DOMAINS`) mapping everyday words and
   problems to the trade that fixes them. This is what lets
   "بدي اصلح حنفية" find a listing called "سباك محترف": the word حنفية is
   known to belong to the plumbing domain, whatever the listing is titled.
4. Scoring of a document against a query from two signals: domain match
   and weighted word overlap (typo tolerant). See `combine`.

Extending it: add words to `DOMAINS` (single words only) or `GENERIC_WORDS`.
"""
import re
from dataclasses import dataclass
from difflib import SequenceMatcher, get_close_matches
from functools import lru_cache
from typing import Optional

# --------------------------------------------------------------------------
# Normalisation & stemming
# --------------------------------------------------------------------------

_DIACRITICS_RE = re.compile(r"[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED\u0640]")
_REPEATED_RE = re.compile(r"(.)\1{2,}")
_TOKEN_RE = re.compile(r"[\u0621-\u064A0-9a-z]+")
_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789")
_LETTER_MAP = str.maketrans(
    {
        "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
        "ى": "ي", "ئ": "ي", "ی": "ي",
        "ة": "ه", "ؤ": "و",
        "ک": "ك", "گ": "ك",
        "ء": None,  # "كهرباء" == "كهربا" == "كهربائي" after stemming
    }
)

_PREFIXES = ("وبال", "وال", "بال", "كال", "فال", "لل", "ال")
# suffix -> shortest stem allowed after removing it (the dual/plural endings
# are stricter so "الكترونيات" is not chopped down to "كتر")
_SUFFIXES = (
    ("ات", 3), ("ان", 4), ("ين", 4), ("ون", 4), ("ها", 3), ("هم", 3),
    ("هن", 3), ("نا", 3), ("ه", 3), ("ي", 3),
)
_ATTACHED_PREFIXES = "وبلفك"   # single letters glued to a word: وتسريب، بصلح
# The colloquial imperfect prefix, as in "بدي حدا يدهنلي الشقة". Only ي is
# stripped (as an extra reading, never in stem()): ا and ت were measured
# against the whole dictionary and both corrupt real words — ا clashes with
# the article ("الحمام" -> "لحمام", which fuzzy-matches "لحام"/welding) and ت
# with nouns that start with it ("تحديد" -> "حديد"/ironwork).
_IMPERFECT_PREFIX = "ي"
# Object pronouns glued to the end of a verb: يدهن + لي. Longest first, so
# "لها" is not read as "له" + a stray alef.
_OBJECT_SUFFIXES = ("لها", "لهم", "لهن", "لنا", "لي", "لك", "له")
_MIN_STEM = 3


def normalize(text: str) -> str:
    """Lower-cases and unifies Arabic spelling variants (see module docstring)."""
    text = (text or "").lower().translate(_DIGITS)
    text = _DIACRITICS_RE.sub("", text)
    text = text.translate(_LETTER_MAP)
    return _REPEATED_RE.sub(r"\1", text)


def tokenize(text: str) -> list[str]:
    """Normalised word tokens (letters and digits only)."""
    return _TOKEN_RE.findall(normalize(text))


def stem(token: str) -> str:
    """
    Light, idempotent stemmer for already-normalised tokens. Strips a leading
    definite article/prefix once, then trailing plural/feminine/pronoun
    endings until nothing more can be removed (never below 3 letters).
    """
    for prefix in _PREFIXES:
        if token.startswith(prefix) and len(token) - len(prefix) >= _MIN_STEM:
            token = token[len(prefix):]
            break
    changed = True
    while changed:
        changed = False
        for suffix, shortest in _SUFFIXES:
            if token.endswith(suffix) and len(token) - len(suffix) >= shortest:
                token = token[: -len(suffix)]
                changed = True
                break
    return token


def stem_variants(token: str) -> frozenset[str]:
    """
    Every reading of `token` worth comparing: its stem, plus the stems it
    would have if some of its letters are grammar rather than part of the
    word. Readings are added, never substituted — the plain stem is always
    in the result — and each added one must still be at least _MIN_STEM
    letters, so nothing is shortened into a different word.

      * one glued-on prefix letter (و ب ل ف ك): we cannot tell "وتسريب"
        (and leaks) from a word that really starts with و;
      * a leading imperfect ي and/or a trailing object pronoun
        (ـلي ـلك ـله ...), so a request phrased the way people speak —
        "بدي حدا يدهنلي الشقة" — reads as "دهن" too and reaches the trade
        the dictionary already knows.

    `stem()` itself is deliberately untouched: these are alternative
    readings of one word, not a claim about which reading is correct.
    """
    variants = {stem(token)}
    if len(token) >= 4 and token[0] in _ATTACHED_PREFIXES:
        rest = stem(token[1:])
        if len(rest) >= _MIN_STEM:
            variants.add(rest)

    # The verb readings: "يدهنلي" -> "يدهن" (no pronoun), "دهنلي" (no
    # prefix) and "دهن" (neither), whichever survive the length floor.
    bases = [token]
    for suffix in _OBJECT_SUFFIXES:
        if token.endswith(suffix) and len(token) - len(suffix) >= _MIN_STEM:
            bases.append(token[: -len(suffix)])
            break
    for base in bases:
        if base != token:
            without_pronoun = stem(base)
            if len(without_pronoun) >= _MIN_STEM:
                variants.add(without_pronoun)
        if base.startswith(_IMPERFECT_PREFIX) and len(base) - 1 >= _MIN_STEM:
            without_prefix = stem(base[1:])
            if len(without_prefix) >= _MIN_STEM:
                variants.add(without_prefix)

    return frozenset(variants)


# --------------------------------------------------------------------------
# Words that carry no meaning for matching, and words that are too generic
# --------------------------------------------------------------------------

_STOPWORDS_RAW = """
بدي بدنا بدك بدو اريد ابغي ابغى عايز عاوز محتاج احتاج لازم ممكن هل لو سمحت تكرم
ابحث دور بدور ادور لقيت حدا احد شخص شي شيء اي ايه ما هاد هاي هذا هذه هيك هادا
في فيه من عن على علي الى الي ان انا نحن انت لي لدي عندي عند مع او ثم كل جدا كتير
شوي بس يا يعني مثل حتى عشان لان اذا اذ قبل بعد فوق تحت ع ب كيف وين اين شو ليش
الي اللي التي الذي هو هي هم نريد اريد ممكن ياريت يرجى رجاء
"""

# Words that describe *a need* but not *which trade*: "repair", "broken", ...
# They still count a little, but never enough to match on their own.
_GENERIC_RAW = """
صلح اصلح يصلح بصلح تصلح مصلح تصليح اصلاح صيانه خدمه خدمات شغل عمل اعمال مساعده
محترف ممتاز سريع رخيص قريب افضل احسن ارخص مشكله مشاكل عطل اعطال عطلان عاطل
خربان خرب خربت مكسور بايظ تعطل تعطلت تركيب تغيير تبديل بدل فحص معاينه
"""

STOPWORDS = {normalize(w) for w in _STOPWORDS_RAW.split()}
GENERIC_WORDS = {stem(normalize(w)) for w in _GENERIC_RAW.split()}

# --------------------------------------------------------------------------
# Knowledge base: domain -> words that point to it (single words only)
# Mix of Modern Standard Arabic and Levantine / Egyptian / Gulf wording.
# --------------------------------------------------------------------------

DOMAINS: dict[str, str] = {
    # ------------------------------------------------------------ البيت والصيانة
    "سباكة": """
        سباك سباكة سبّاك حنفية حنفيات صنبور مواسير ماسورة انابيب انبوب تسريب
        تسرب تنقيط مجاري مجرى بالوعة بلاعة انسداد سدة مسدود صرف تصريف سخان سخانات
        بويلر خلاط مغسلة حوض مرحاض توليت سيفون حمام حمامات مياه ميه خزان شطاف
        بانيو صحي صحية فلتر
    """,
    "كهرباء": """
        كهربائي كهربجي كهرباء كهربا كهربائية سلك اسلاك كبل كابل قاطع فيوز بريزة
        برايز تيار لمبة لمبات اضاءة انارة ثريا ثريات ليد مولد مولدة مولدات جنريتر
        تاريض عداد
    """,
    "طاقة شمسية": """
        شمسية شمسي الواح طاقة انفرتر انفيرتر بطاريات ليثيوم ups
    """,
    "تكييف وتبريد": """
        تكييف مكيف مكيفات تكيف كونديشن سبليت تبريد براد برادات ثلاجة ثلاجات فريزر
        فريون ضاغط كمبروسر
    """,
    "تدفئة": """
        تدفئة مدفأة مدافئ صوبة صوبيا دفاية رادياتير مازوت
    """,
    "نجارة": """
        نجار نجارة خشب اخشاب باب ابواب خزانة خزائن دولاب تفصيل مكتبة سرير
        ورنيش موبيليا اثاث باركيه نجارين مطبخ مطابخ
    """,
    "دهان وديكور": """
        دهان دهانات دهّان طلاء بوية صباغ صباغة دهن جبس جبصين بلاستر معجون ديكور
        ورق جدران
    """,
    "هندسة وتصميم داخلي": """
        مهندس هندسة معماري معمارية مخطط مخططات خرائط اشراف مساحة تراخيص ديكور
        داخلي
    """,
    "بناء وتشطيب": """
        بناء بنّاء معمار مقاول مقاولات ترميم ترميمات تشطيب تشطيبات بلاط سيراميك
        رخام جرانيت تبليط قصارة لياسة طوب بلوك اسمنت باطون عزل رطوبة جدران هدم
        تكسير حفر
    """,
    "حدادة وألمنيوم": """
        حداد حدادة لحام لحامة حديد المنيوم زجاج شبابيك نوافذ بوابات سور درابزين
        مظلات خراط خراطة
    """,
    "تنجيد": """
        تنجيد منجد كنبة كنبات كنب كراسي مقاعد اسفنج
    """,
    "خياطة": """
        خياط خياطة فستان فساتين تطريز ثوب عباية ستائر ستارة مفروشات
        تقصير
    """,
    # "نضف" and "نظف" are the bare root, not spelling variants of "تنضيف" /
    # "تنظيف": the stemmer does not strip the ت, so "بدي حدا ينضفلي البيت" —
    # which reads as "نضف" — reached no trade without it. Both spellings are
    # listed because normalisation does not unify ض and ظ, and each is a
    # separate index key: the colloquial ض and the standard ظ.
    "تنظيف": """
        تنظيف نظافة تنضيف نضف نظف شغالة عاملة خادمة جلي مكنسة غسيل سجاد موكيت
        تعقيم تلميع منظفات
    """,
    "مكافحة حشرات": """
        حشرات صراصير نمل رش مبيدات مكافحة فئران قوارض بق
    """,
    "نقل وتوصيل": """
        نقل شحن نقليات عفش توصيل دليفري ديلفري بيك بكب سطحة ونش رافعة تغليف
        ترحيل طرود
    """,
    "أمن وأقفال": """
        كاميرات مراقبة انذار حراسة بصمة قفال قفل اقفال
    """,
    "حدائق وزراعة": """
        حديقة حدائق بستاني بستنة زراعة عشب نجيلة تقليم شجر اشجار ورد نباتات ري
        تشجير
    """,
    # ---------------------------------------------------- إلكترونيات وصيانة أجهزة
    "إلكترونيات": """
        الكترونيات الكترونية الكترونيك دارة دارات بورد مذربورد شريحة شرائح معالج
        مكثف مكثفات ترانزستور حساس حساسات اردوينو سماعات شاحن شواحن راديو
        تلفزيون تلفاز شاشات شاشة
    """,
    "صيانة جوالات": """
        جوال جوالات موبايل موبايلات هاتف هواتف تلفون تلفونات ايفون ايفونات سامسونج
        هواوي شاومي اوبو ريدمي شاشة بطارية شاحن كفر فلاش سوفتوير ريسيت
        فورمات تفليش تكسر حظر
    """,
    "صيانة حواسيب": """
        لابتوب لابتوبات لاب كمبيوتر كمبيوترات كومبيوتر حاسوب حواسيب حاسب حواسب
        ماك ماكبوك ويندوز فورمات هارد رام فيروس فيروسات سوفتوير تعريف تجميع بيسي
        طابعة طابعات شاشة بطارية كيبورد
    """,
    "شبكات واتصالات": """
        راوتر شبكة شبكات واي فاي انترنت سلكي لاسلكي لان كابلات تقوية ايرياب
        سنترال مقسم
    """,
    # "غاز" belongs here with the appliances that burn it (فرن، بوتاجاز،
    # طباخ): a customer who writes "في ريحة غاز بالمطبخ" wants the oven/gas
    # technician. It is deliberately not filed under تكييف وتبريد, whose gas
    # is فريون (refrigerant, a different substance), nor under سباكة, which
    # carries no gas-piping vocabulary at all.
    "صيانة أجهزة منزلية": """
        غسالة غسالات جلاية فرن بوتاجاز غاز طباخ ميكرويف تلفزيون تلفاز ستالايت
        ستلايت ريسيفر اجهزة كهربائيات خلاط مكنسة براد ثلاجة
    """,
    # ------------------------------------------------------------ برمجة وتصميم
    "برمجة وتطوير": """
        برمجة مبرمج مبرمجين برنامج برامج برمجيات تطبيق تطبيقات موقع مواقع ويب
        تطوير مطور مطورين سيرفر سيرفرات بيانات باك فرونت اندرويد
        بايثون جافا جافاسكربت فلاتر ريأكت لارافيل ووردبريس سكربت اتمتة بوت بوتات
        استضافة دومين متجر ذكاء php api html css python java
        flutter react wordpress
    """,
    "تصميم وجرافيك": """
        مصمم مصممين تصميم تصاميم جرافيك شعار شعارات لوغو لوجو هوية بوستر
        بنر فوتوشوب اليستريتور كانفا واجهات مونتاج فيديو موشن انيميشن رسم رسام
        انفوجرافيك
    """,
    "تصوير": """
        تصوير مصور مصورين فوتوغراف فوتوغرافي كاميرا درون البوم تصويره
    """,
    "تسويق وإعلان": """
        تسويق اعلان اعلانات دعاية سوشيال ميديا انستغرام فيسبوك تيك توك سيو حملات
        ممولة محتوى صفحات
    """,
    "طباعة وإعلانات": """
        طباعة مطبعة لافتات بانر ستيكر يافطة بروشور كرت كروت دعايه
    """,
    # ------------------------------------------------------------ لغات وتعليم
    "ترجمة ولغات": """
        ترجمة ترجمات مترجم مترجمين ترجم تعريب فوري تحريري لغات لغة انجليزي
        انكليزي فرنسي تركي الماني المانيا اسباني ايطالي روسي صيني مستندات وثائق
        محلف معتمدة معتمد تدقيق تفريغ نصوص
    """,
    # "يعلم" is listed, not the bare root "علم". Indexing keys a word on
    # stem(normalize(word)), so this entry is the single key "يعلم", which
    # "بدي حدا يعلم ابني" reaches and "ما بعلم" (= I don't know, readings
    # {بعلم, علم}) does not — the root itself would have served both, and
    # measurably demoted the right answer for the second.
    "تعليم ودروس": """
        دروس درس خصوصي خصوصية معلم يعلم مدرس استاذ تدريس تعليم رياضيات فيزياء
        كيمياء انجليزي قران تجويد تقوية واجبات امتحان توجيهي بكالوريا تاسيس
        احياء علوم مدرسة طالب طلاب
    """,
    "كتابة وتحرير": """
        كتابة كاتب مقال مقالات تدقيق لغوي محتوى تحرير نصوص خطابات
    """,
    # ------------------------------------------------------------ سيارات
    "سيارات": """
        ميكانيك ميكانيكي سيارة سيارات محرك موتور فرامل زيت بنزين سمكري سمكرة بنشر
        كفرات اطارات جنط قير رادياتور عفشة
    """,
    # ------------------------------------------------------------ جمال وصحة
    "حلاقة رجالية": """
        حلاق حلاقة حلاقه قص قصة قصه شعر ذقن دقن لحية تشذيب تحديد فيد ستايل
        رجالي
    """,
    "تجميل وعناية": """
        تجميل مكياج ميكب تسريحة تسريحات كوافير كوافيرة صالون شعر صبغة كيراتين بروتين تمليس سشوار
        اظافر مانيكير بديكير حنة بشرة تقشير ماسك ليزر شمع حواجب رموش
        عروس وشم
    """,
    "تمريض وصحة": """
        ممرض ممرضة تمريض حقن سيروم مسن مسنين عجوز مرافق مرافقة فيزيو مساج تدليك
        اسعافات
    """,
    "طب وأسنان": """
        طبيب دكتور عيادة اسنان تقويم حشوة علاج عصب تبييض
    """,
    "رعاية أطفال": """
        حضانة جليسة مربية رعاية اطفال طفل رضيع بيبي
    """,
    "رعاية حيوانات": """
        بيطري بيطرية حيوانات اليفة قطط قطة كلاب كلب تدريب ببغاء عصافير اسماك
    """,
    "رياضة ولياقة": """
        مدرب تدريب لياقة رياضة جيم نادي تخسيس دايت رجيم تغذية يوغا سباحة كاراتيه
        ملاكمة
    """,
    # ------------------------------------------------------------ طعام ومناسبات
    "طبخ وضيافة": """
        طبخ طباخ طباخة شيف اكل وجبات وجبة بيتي حلويات كيك كعك معجنات تورتة بوفيه
        ضيافة عزيمة تموين ماكولات ولائم مقبلات فطائر
    """,
    "مناسبات وأفراح": """
        فرح افراح عرس اعراس حفلة حفلات مناسبة مناسبات بالونات زفة خيمة تاجير
    """,
    # ------------------------------------------------------------ مكتبية وقانونية
    "خدمات مكتبية وقانونية": """
        محاسب محاسبة محامي محاماة قانون استشارة استشارات ضرائب طباعة معاملات
        معقب تخليص
    """,
}

# Trades that overlap in real life: a query for one is still a reasonable
# (but weaker) hint for the other. Pairs are symmetric.
_RELATED_PAIRS = [
    ("إلكترونيات", "صيانة جوالات"),
    ("إلكترونيات", "صيانة حواسيب"),
    ("إلكترونيات", "صيانة أجهزة منزلية"),
    ("صيانة جوالات", "صيانة حواسيب"),
    ("شبكات واتصالات", "صيانة حواسيب"),
    ("حلاقة رجالية", "تجميل وعناية"),
    ("برمجة وتطوير", "تصميم وجرافيك"),
    ("تسويق وإعلان", "تصميم وجرافيك"),
    ("تسويق وإعلان", "طباعة وإعلانات"),
    ("كهرباء", "طاقة شمسية"),
    ("ترجمة ولغات", "تعليم ودروس"),
    ("هندسة وتصميم داخلي", "دهان وديكور"),
    ("هندسة وتصميم داخلي", "بناء وتشطيب"),
    ("نجارة", "تنجيد"),
    ("طب وأسنان", "تمريض وصحة"),
    ("كتابة وتحرير", "ترجمة ولغات"),
]
RELATED: dict[str, set[str]] = {}
for _a, _b in _RELATED_PAIRS:
    RELATED.setdefault(_a, set()).add(_b)
    RELATED.setdefault(_b, set()).add(_a)

# stem -> domains it points to
_DOMAIN_INDEX: dict[str, set[str]] = {}
for _domain, _words in DOMAINS.items():
    for _word in _words.split():
        _s = stem(normalize(_word))
        if len(_s) >= 2 and _s not in STOPWORDS:
            _DOMAIN_INDEX.setdefault(_s, set()).add(_domain)
_DOMAIN_STEMS = sorted(_DOMAIN_INDEX)

_FUZZY_DOMAIN_CUTOFF = 0.86
_FUZZY_WORD_CUTOFF = 0.84

_DOMAIN_STEMS_BY_LENGTH: dict[int, list[str]] = {}
for _s in _DOMAIN_STEMS:
    _DOMAIN_STEMS_BY_LENGTH.setdefault(len(_s), []).append(_s)


@lru_cache(maxsize=None)
def _fuzzy_domain_candidates(length: int) -> tuple[str, ...]:
    """
    The domain stems a word of `length` letters could possibly match.

    difflib.get_close_matches drops a candidate as soon as its length alone
    rules the cutoff out (SequenceMatcher.real_quick_ratio, which is
    2*min(la, lb)/(la+lb)). This applies that very same test once per length
    instead of once per candidate per lookup, so the stems handed to
    get_close_matches are exactly the ones it would have kept anyway and
    the result is identical.
    """
    return tuple(
        candidate
        for candidate_length, candidates in sorted(_DOMAIN_STEMS_BY_LENGTH.items())
        if 2.0 * min(length, candidate_length) / (length + candidate_length) >= _FUZZY_DOMAIN_CUTOFF
        for candidate in candidates
    )


# Memoised: a pure function of the stem, and the same words come back in
# service after service and query after query. The fuzzy lookup below was
# ~97% of the time of a cold ranking. Bounded so that arbitrary search text
# cannot grow it without limit (an entry is a short string and a tiny set).
@lru_cache(maxsize=65536)
def _domains_of_stem(token_stem: str) -> frozenset[str]:
    """Domains a stem points to, tolerating small typos for longer words."""
    exact = _DOMAIN_INDEX.get(token_stem)
    if exact:
        return frozenset(exact)
    if len(token_stem) >= 4:
        close = get_close_matches(
            token_stem,
            _fuzzy_domain_candidates(len(token_stem)),
            n=2,
            cutoff=_FUZZY_DOMAIN_CUTOFF,
        )
        found: set[str] = set()
        for word in close:
            found |= _DOMAIN_INDEX[word]
        return frozenset(found)
    return frozenset()


# --------------------------------------------------------------------------
# Query & document analysis
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class QueryInfo:
    stems: tuple[str, ...]            # informative stems, in order
    weights: tuple[float, ...]        # 1.0 normal, 0.3 generic
    domains: frozenset[str]           # trades the query points to
    variants: tuple[frozenset[str], ...] = ()   # every reading of each stem

    @property
    def is_empty(self) -> bool:
        return not self.stems


def analyze_query(query: str) -> QueryInfo:
    stems: list[str] = []
    weights: list[float] = []
    variants: list[frozenset[str]] = []
    domains: set[str] = set()
    seen: set[str] = set()
    for token in tokenize(query):
        if token in STOPWORDS or len(token) < 2:
            continue
        token_stem = stem(token)
        if token_stem in STOPWORDS or token_stem in seen:
            continue
        seen.add(token_stem)
        stems.append(token_stem)
        is_generic = token_stem in GENERIC_WORDS
        readings = stem_variants(token)
        weights.append(0.3 if is_generic else 1.0)
        variants.append(readings)
        if not is_generic:
            domains |= _domains_of_stem(token_stem)
            for reading in readings - {token_stem}:
                domains |= _DOMAIN_INDEX.get(reading, set())
    return QueryInfo(tuple(stems), tuple(weights), frozenset(domains), tuple(variants))


@dataclass(frozen=True)
class DocInfo:
    strong_stems: frozenset[str]      # from title + custom label + category
    weak_stems: frozenset[str]        # from description
    strong_domains: frozenset[str]
    weak_domains: frozenset[str]


# One entry per distinct service text. It must hold the whole catalog: with
# more services than entries, every search evicts and re-analyses all of them
# (measured: 0 cache hits at 5,000 services with the former 4,096). An entry
# is about 5 KB, so the cache costs ~5 MB per 1,000 services.
@lru_cache(maxsize=16384)
def analyze_doc(title: str, label: str, category: str, description: str) -> DocInfo:
    strong: set[str] = set()
    for t in tokenize(f"{title} {label} {category}"):
        if t not in STOPWORDS:
            strong |= stem_variants(t)
    weak: set[str] = set()
    for t in tokenize(description):
        if t not in STOPWORDS:
            weak |= stem_variants(t)
    weak -= strong
    strong_domains: set[str] = set()
    weak_domains: set[str] = set()
    for s in strong:
        strong_domains |= _domains_of_stem(s)
    for s in weak:
        weak_domains |= _domains_of_stem(s)
    return DocInfo(
        frozenset(strong), frozenset(weak),
        frozenset(strong_domains), frozenset(weak_domains - strong_domains),
    )


# Memoised: a search compares each query word with every word of every
# candidate service, and the same (query word, service word) pairs come back
# for service after service and search after search. This comparison was
# ~98% of the time of a search over an already-analysed catalog. The argument
# order is part of the key (SequenceMatcher.ratio is not symmetric).
@lru_cache(maxsize=131072)
def _fuzzy_ratio_reaches_cutoff(word: str, other: str) -> bool:
    return SequenceMatcher(None, word, other).ratio() >= _FUZZY_WORD_CUTOFF


def _near_miss(word: str, other: str) -> bool:
    """True when two words (4+ letters each) differ only by a small typo."""
    length, other_length = len(word), len(other)
    # ratio() is 2*M/(la+lb) with M <= min(la, lb), so it can never exceed
    # 2*min(la, lb)/(la+lb) (SequenceMatcher.real_quick_ratio): when even
    # that bound is under the cutoff the pair cannot match, and the real
    # comparison is skipped. Never changes the answer.
    if 2.0 * min(length, other_length) / (length + other_length) < _FUZZY_WORD_CUTOFF:
        return False
    return _fuzzy_ratio_reaches_cutoff(word, other)


def _word_match(readings, stems: frozenset[str]) -> bool:
    """True if any reading of a query word is in `stems` (or is a near-miss typo)."""
    if isinstance(readings, str):
        readings = (readings,)
    if any(word in stems for word in readings):
        return True
    return any(
        len(word) >= 4 and len(other) >= 4 and _near_miss(word, other)
        for word in readings
        for other in stems
    )


def domain_score(info: QueryInfo, doc: DocInfo) -> float:
    """0..1 — how much of what the query asks for is the trade this service offers."""
    if not info.domains:
        return 0.0
    total = 0.0
    for domain in info.domains:
        if domain in doc.strong_domains:
            total += 1.0
        elif domain in doc.weak_domains:
            total += 0.5
        elif RELATED.get(domain, set()) & doc.strong_domains:
            total += 0.5   # a neighbouring trade, e.g. phones <-> laptops
        elif RELATED.get(domain, set()) & doc.weak_domains:
            total += 0.3
    return total / len(info.domains)


def lexical_score(info: QueryInfo, doc: DocInfo) -> float:
    """0..1 — weighted share of the query's words found in the service
    (title/category count fully, description partly, small typos tolerated)."""
    if info.is_empty:
        return 0.0
    got = 0.0
    total = 0.0
    readings = info.variants or tuple(frozenset({w}) for w in info.stems)
    for word, weight in zip(readings, info.weights):
        total += weight
        if _word_match(word, doc.strong_stems):
            got += weight
        elif _word_match(word, doc.weak_stems):
            got += weight * 0.6
    return got / total if total else 0.0


def labels_equivalent(a: Optional[str], b: Optional[str]) -> bool:
    """
    True when two free-text trade labels name the same kind of service —
    used for the «أخرى» (Other) category, where the custom label (e.g.
    "سباك") is the only thing that says what is actually offered/wanted.

    Deliberately stricter than search relevance (this decides *equality*,
    for exchange matching, not "related"):
      * identical after normalisation ("مُبَرْمِج" == "مبرمج") -> equal;
      * when the knowledge base recognises a trade in BOTH labels, they are
        equal only if they share a trade ("سباك" == "تصليح حنفيات", but
        "سباك" != "نجار");
      * otherwise every informative word of the shorter label must appear
        (typo tolerant) in the other one.
    An empty/missing label never matches anything: an unlabelled «أخرى»
    tells us nothing about the service.
    """
    na, nb = normalize(a or "").strip(), normalize(b or "").strip()
    if not na or not nb:
        return False
    if na == nb:
        return True
    qa, qb = analyze_query(na), analyze_query(nb)
    if qa.domains and qb.domains:
        return bool(qa.domains & qb.domains)

    def informative(info: QueryInfo) -> list[frozenset[str]]:
        readings = info.variants or tuple(frozenset({s}) for s in info.stems)
        return [r for r, w in zip(readings, info.weights) if w >= 1.0]

    words_a, words_b = informative(qa), informative(qb)
    if not words_a or not words_b:
        return False
    if len(words_a) > len(words_b):
        words_a, words_b = words_b, words_a
    pool = frozenset().union(*words_b)
    return all(_word_match(readings, pool) for readings in words_a)


MIN_SCORE = 0.25


def combine(domain: float, lexical: float) -> float:
    """Final 0..1 relevance: trade 55% + words 45%."""
    return 0.55 * domain + 0.45 * lexical


@dataclass(frozen=True)
class SearchDoc:
    id: int
    title: str
    description: str = ""
    category: str = ""
    label: str = ""


def rank(
    query: str,
    docs: list[SearchDoc],
    min_score: float = MIN_SCORE,
) -> list[tuple[int, float]]:
    """
    Ranks `docs` for `query`. Returns [(doc_id, score)] best first, dropping
    anything under `min_score`.
    """
    info = analyze_query(query)
    if info.is_empty:
        return []
    scored: list[tuple[int, float]] = []
    for doc in docs:
        analysed = analyze_doc(doc.title, doc.label, doc.category, doc.description)
        score = combine(domain_score(info, analysed), lexical_score(info, analysed))
        if score >= min_score:
            scored.append((doc.id, round(score, 4)))
    scored.sort(key=lambda pair: (-pair[1], pair[0]))
    return scored
