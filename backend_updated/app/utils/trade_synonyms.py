"""
Everyday words for every trade (مهنة), handed to the embedding model together
with the user's query.

The model on its own does not know that «جوال» is a phone: on the real
catalogue the raw query scored −0.16 (earlier MiniLM model) against the listing «تصليح كافة اجهزة
الموبايل واللابتوب». Sent together with the trade and its words, it scores
far higher. Measured alternatives:

  * one text: query + trade name + a few of its words (what this module
    produces) — best;
  * the best of the synonyms embedded one by one — worse: one stray synonym
    is enough to lift an unrelated listing (the locksmith reached 0.48);
  * the average of those vectors — weaker on every query tried;
  * the whole synonym list — drowns the user's own words (see _CORE_WORDS);
  * the query's own vector added to the expanded one — no better than this.

How a trade is chosen: every SINGLE-word entry below is a trigger. A query
word triggers a trade when one of its readings (`stem_variants`: with or
without ال, plural endings, glued-on و/ب, …) equals the stem of a trigger.
Exact only — no typo tolerance — so a near-spelling cannot drag a trade in.
Multi-word entries never trigger anything; they are there to give the model
the meaning of the trade.

Each trigger belongs to exactly one trade (tests/test_trade_synonyms.py
enforces it). Words that honestly mean two things are left out as triggers
on purpose — a wrong trade with all its synonyms is worse than no hint at
all. Each of these was measured doing damage, or shares a stem with a word
that means something else:

  * «شاشة» phone / laptop / TV;  «شعر» barber / beauty salon;
  * «طباخ» a cook / a stove;  «براد» «ثلاجة» refrigeration / appliances;
  * «معلم» a teacher, and in Levantine the master craftsman
    («بدي معلم يركب لي مجلى» wants a plumber);
  * «برنامج» software / a washing-machine cycle;
  * «أكل» cooking / the food going off in a broken fridge;
  * «رياضة» shares its stem with «رياضيات» (maths lessons);
  * «إلكترونيات» shares its stem with «الكتروني» («موقع الكتروني» is a website).

They may still appear inside a phrase, which never triggers.

The keys are the trade names, i.e. the category names in the database
(see scripts/seed_categories.py). «Others» has no entry: it is a catch-all
and its custom label is free text.
"""
from app.utils.arabic_search import (
    GENERIC_WORDS,
    STOPWORDS,
    normalize,
    stem,
    stem_variants,
    tokenize,
)

TRADE_SYNONYMS: dict[str, tuple[str, ...]] = {
    # ------------------------------------------------------------ البيت والصيانة
    "سباكة": (
        "سباك", "سباكة", "حنفية", "حنفيات", "مواسير", "بواري", "تسريب", "مجاري",
        "بالوعة", "سخان", "شطاف", "مرحاض",
        # «مغاسل» sits beside «مغسلة» because the two do not share a stem
        # (مغاسل vs مغسل), so the plural is not reached from the singular.
        # Neither shares one with «غسالة» (a washing machine, under أجهزة
        # منزلية), whose stem is غسال.
        "مغسلة", "مغاسل", "مجلى",
        "تسريب مياه", "تمديدات صحية", "تسليك مجاري",
    ),
    "كهرباء": (
        "كهربائي", "كهربجي", "كهرباء", "فيوز", "بريزة", "قاطع", "لمبة", "إنارة",
        "مولدة", "ثريا",
        "تمديدات كهربائية", "تمديد أسلاك", "انقطاع الكهرباء",
    ),
    "طاقة شمسية": (
        "شمسية", "انفرتر", "ليثيوم",
        "طاقة شمسية", "ألواح شمسية", "منظومة طاقة", "بطاريات ليثيوم",
    ),
    "تكييف وتبريد": (
        "مكيف", "مكيفات", "تكييف", "كونديشن", "سبليت", "تبريد", "فريون",
        "كمبروسر",
        "تصليح مكيفات", "شحن غاز فريون", "تبريد مركزي",
    ),
    "تدفئة": (
        "تدفئة", "مدفأة", "مدافئ", "صوبة", "صوبيا", "دفاية", "شوفاج", "مازوت",
        "تدفئة مركزية", "تصليح مدافئ",
    ),
    "نجارة": (
        "نجار", "نجارة", "خشب", "موبيليا", "دولاب", "باركيه", "ورنيش",
        "تفصيل مطابخ", "أبواب خشب", "خزائن ودواليب", "تصليح أثاث خشبي",
    ),
    "دهان وديكور": (
        "دهان", "دهانات", "طلاء", "بوية", "صباغ", "جبصين", "جبس", "ديكور",
        "دهان شقق", "ورق جدران", "ديكورات جبس",
    ),
    "هندسة وتصميم داخلي": (
        "مهندس", "هندسة", "معماري", "مخططات", "خرائط",
        "تصميم داخلي", "إشراف هندسي", "رسم مخططات", "مهندس ديكور",
    ),
    "بناء وتشطيب": (
        "بناء", "مقاول", "مقاولات", "بلاط", "سيراميك", "تبليط", "ترميم", "تشطيب",
        "لياسة", "قصارة", "باطون",
        "عزل رطوبة", "ترميم بيوت", "تشطيب شقق",
    ),
    "حدادة وألمنيوم": (
        "حداد", "حدادة", "لحام", "ألمنيوم", "حديد", "شبابيك", "درابزين",
        "أبواب حديد", "شبابيك ألمنيوم", "مطابخ ألمنيوم",
    ),
    "تنجيد": (
        "تنجيد", "منجد", "كنب", "كنبة", "اسفنج",
        "تنجيد كنب", "تغيير قماش الكنب", "تنجيد كراسي",
    ),
    "خياطة": (
        "خياط", "خياطة", "تطريز", "فستان", "فساتين", "ستائر",
        "تفصيل ملابس", "تعديل ملابس", "خياطة ستائر",
    ),
    "تنظيف": (
        "تنظيف", "تنضيف", "نظافة", "تعقيم", "منظفات", "موكيت",
        "تنظيف بيوت", "تنظيف شقق", "تنظيف سجاد",
    ),
    "مكافحة حشرات": (
        "حشرات", "صراصير", "مبيدات", "فئران", "قوارض", "نمل",
        "مكافحة حشرات", "رش مبيدات", "إبادة صراصير",
    ),
    "نقل وتوصيل": (
        "نقل", "نقليات", "عفش", "توصيل", "دليفري", "ديلفري", "سطحة", "ونش",
        "نقل عفش", "نقل أثاث", "توصيل طلبات",
    ),
    "أمن وأقفال": (
        "قفل", "أقفال", "قفال", "كالون", "كاميرات", "مراقبة", "إنذار", "حراسة",
        "فتح أبواب", "كاميرات مراقبة", "تبديل كالون",
    ),
    "حدائق وزراعة": (
        "حديقة", "حدائق", "بستاني", "زراعة", "عشب", "تقليم", "تشجير", "نباتات",
        "تنسيق حدائق", "قص عشب", "تصميم حدائق",
    ),
    # ---------------------------------------------------- إلكترونيات وصيانة أجهزة
    "إلكترونيات": (
        "بورد", "مذربورد", "اردوينو", "سماعات", "تلفزيون", "تلفاز",
        "تصليح أجهزة إلكترونية", "صيانة بوردات", "قطع إلكترونية",
    ),
    "صيانة جوالات": (
        "جوال", "جوالات", "موبايل", "موبايلات", "هاتف", "هواتف", "تلفون",
        "تلفونات", "خلوي", "ايفون", "سامسونج",
        "صيانة جوالات", "تصليح موبايلات", "تبديل شاشة جوال", "هاتف محمول",
    ),
    "صيانة حواسيب": (
        "كمبيوتر", "كومبيوتر", "حاسوب", "حواسيب", "حاسب", "لابتوب", "لابتوبات",
        "ماكبوك", "بيسي", "طابعة", "ويندوز",
        "صيانة حواسيب", "تصليح لابتوبات", "فورمات وتنزيل ويندوز", "تجميع كمبيوتر",
    ),
    "شبكات واتصالات": (
        "راوتر", "شبكة", "شبكات", "انترنت", "wifi", "سنترال", "مقسم",
        "تمديد شبكات", "تقوية واي فاي", "مشكلة انترنت",
    ),
    "صيانة أجهزة منزلية": (
        "غسالة", "غسالات", "جلاية", "فرن", "بوتاجاز", "غاز", "ميكرويف",
        "ريسيفر", "ستلايت",
        "صيانة غسالات", "تصليح أفران غاز", "تصليح برادات وثلاجات",
        "صيانة أجهزة منزلية",
    ),
    # ------------------------------------------------------------ برمجة وتصميم
    "برمجة وتطوير": (
        "برمجة", "مبرمج", "برمجيات", "تطبيق", "تطبيقات", "موقع",
        "مواقع", "ويب", "سيرفر", "اندرويد", "بايثون", "ووردبريس", "python",
        "flutter",
        "تصميم مواقع", "برمجة تطبيقات موبايل", "متجر إلكتروني",
    ),
    "تصميم وجرافيك": (
        "مصمم", "جرافيك", "غرافيك", "شعار", "لوغو", "لوجو", "بوستر", "فوتوشوب",
        "مونتاج",
        "تصميم شعار", "هوية بصرية", "تصميم سوشيال ميديا",
    ),
    "تصوير": (
        "تصوير", "مصور", "فوتوغراف", "كاميرا", "درون",
        "تصوير أعراس", "تصوير منتجات", "جلسة تصوير",
    ),
    "تسويق وإعلان": (
        "تسويق", "مسوق", "إعلان", "إعلانات", "سوشيال", "انستغرام", "فيسبوك",
        "سيو",
        "تسويق إلكتروني", "إدارة صفحات", "حملات ممولة",
    ),
    "طباعة وإعلانات": (
        "طباعة", "مطبعة", "لافتات", "يافطة", "ستيكر", "بروشور", "كروت",
        "طباعة لافتات", "طباعة كروت شخصية", "طباعة بنرات",
    ),
    # ------------------------------------------------------------ لغات وتعليم
    "ترجمة ولغات": (
        "ترجمة", "مترجم", "تعريب", "محلف",
        "ترجمة مستندات", "ترجمة محلفة", "ترجمة من الإنجليزي للعربي",
    ),
    "تعليم ودروس": (
        "دروس", "درس", "مدرس", "أستاذ", "تدريس", "فيزياء", "كيمياء",
        "توجيهي", "بكالوريا",
        "دروس خصوصية", "دروس رياضيات", "تقوية مدرسية",
    ),
    "كتابة وتحرير": (
        "كتابة", "كاتب", "مقالات", "تحرير", "تدقيق",
        "كتابة محتوى", "كتابة مقالات", "تدقيق لغوي",
    ),
    # ------------------------------------------------------------ سيارات
    "سيارات": (
        "سيارة", "سيارات", "ميكانيك", "ميكانيكي", "كراج", "محرك", "فرامل",
        "سمكري", "بنشر",
        "تصليح سيارات", "تبديل زيت", "صيانة سيارات",
    ),
    # ------------------------------------------------------------ جمال وصحة
    "حلاقة رجالية": (
        "حلاق", "حلاقة", "ذقن", "دقن", "لحية",
        "قص شعر رجالي", "تشذيب لحية", "حلاقة رجالية",
    ),
    "تجميل وعناية": (
        "تجميل", "مكياج", "ميكب", "كوافير", "كوافيرة", "كيراتين", "مانيكير",
        "بديكير", "حواجب", "رموش",
        "مكياج عروس", "عناية بالبشرة", "تسريحات شعر",
    ),
    "تمريض وصحة": (
        "ممرض", "ممرضة", "تمريض", "حقن", "سيروم", "مسنين", "مساج", "تدليك",
        "فيزيو",
        "تمريض منزلي", "رعاية مسنين", "علاج فيزيائي",
    ),
    "طب وأسنان": (
        "طبيب", "دكتور", "عيادة", "أسنان", "تقويم", "حشوة",
        "طبيب أسنان", "تبييض أسنان", "زيارة طبيب منزلية",
    ),
    "رعاية أطفال": (
        "جليسة", "مربية", "حضانة", "بيبي", "رضيع", "أطفال", "طفل",
        "جليسة أطفال", "رعاية أطفال", "بيبي سيتر",
    ),
    "رعاية حيوانات": (
        "بيطري", "حيوانات", "قطط", "قطة", "كلاب", "كلب",
        "طبيب بيطري", "رعاية حيوانات أليفة", "تدريب كلاب",
    ),
    "رياضة ولياقة": (
        "لياقة", "جيم", "مدرب", "تخسيس", "رجيم", "دايت", "يوغا", "سباحة",
        "مدرب شخصي", "خسارة وزن", "تمارين رياضية",
    ),
    # ------------------------------------------------------------ طعام ومناسبات
    "طبخ وضيافة": (
        "طبخ", "شيف", "حلويات", "كيك", "معجنات", "بوفيه", "ضيافة", "ولائم",
        "أكل بيتي", "طبخ ولائم", "تحضير بوفيه",
    ),
    "مناسبات وأفراح": (
        "عرس", "أعراس", "حفلة", "حفلات", "مناسبات", "زفة", "فرح",
        "تنظيم حفلات", "تجهيز أعراس", "حفلات أعياد ميلاد",
    ),
    # ------------------------------------------------------------ مكتبية وقانونية
    "خدمات مكتبية وقانونية": (
        "محامي", "محاماة", "محاسب", "محاسبة", "قانون", "قانونية", "ضرائب",
        "معاملات", "معقب",
        "استشارة قانونية", "خدمات محاسبة", "تخليص معاملات",
    ),
}

_MIN_TRIGGER = 3
# How many of a trade's words go to the model. Every word still TRIGGERS the
# trade; only the first few are embedded. The whole list drowns the user's
# own words — «مدرس لغة انجليزية» became "a teacher" and the science tutor
# overtook the English one. On the 29-query set, meaning alone, cut-off
# 0.30, with the earlier MiniLM model: no synonyms 15/29 first, whole list
# 14/29, six words 17/29, three words 18/29.
_CORE_WORDS = 3


def _trigger_stem(entry: str) -> str | None:
    """The stem a single-word entry triggers on, or None for a phrase or for a
    word too short or too general to name a trade («تصليح», «خدمة»)."""
    tokens = tokenize(entry)
    if len(tokens) != 1:
        return None
    entry_stem = stem(tokens[0])
    if len(entry_stem) < _MIN_TRIGGER or entry_stem in STOPWORDS or entry_stem in GENERIC_WORDS:
        return None
    return entry_stem


_TRIGGERS: dict[str, set[str]] = {}
for _trade, _entries in TRADE_SYNONYMS.items():
    for _entry in _entries:
        _s = _trigger_stem(_entry)
        if _s is not None:
            _TRIGGERS.setdefault(_s, set()).add(_trade)


def _core_words(entries: tuple[str, ...]) -> tuple[str, ...]:
    """The first _CORE_WORDS trigger words of a trade that are different
    words, not «جوال» and «جوالات» twice."""
    picked: list[str] = []
    seen: set[str] = set()
    for entry in entries:
        entry_stem = _trigger_stem(entry)
        if entry_stem is not None and entry_stem not in seen:
            seen.add(entry_stem)
            picked.append(entry)
            if len(picked) == _CORE_WORDS:
                break
    return tuple(picked)


_CORE: dict[str, tuple[str, ...]] = {
    trade: _core_words(entries) for trade, entries in TRADE_SYNONYMS.items()
}


def _specific_name(trade: str) -> str:
    """
    The trade name without its general words: «صيانة حواسيب» -> «حواسيب».
    «صيانة» is in every repair listing, so the model read «كمبيوتر» as close
    to a locksmith who does «تركيب وصيانة»: 0.331 with the word, 0.240
    without (earlier MiniLM model).
    """
    return " ".join(
        word for word in trade.split() if stem(normalize(word)) not in GENERIC_WORDS
    )


_NAMES: dict[str, str] = {trade: _specific_name(trade) for trade in TRADE_SYNONYMS}


def core_words(trade: str) -> tuple[str, ...]:
    """
    The few everyday words that stand for `trade` — the same ones `expand`
    sends alongside a query that names it.

    Empty for a trade with no entry here: «أخرى», whose label is free text, or
    a category added to the database after this table.
    """
    return _CORE.get(trade, ())


def trades_in(query: str) -> frozenset[str]:
    """The trades whose words appear in `query` (exact, after normalising)."""
    found: set[str] = set()
    for token in tokenize(query):
        if token in STOPWORDS:
            continue
        for reading in stem_variants(token):
            found |= _TRIGGERS.get(reading, set())
    return frozenset(found)


def expand(query: str) -> str:
    """
    The text to embed for `query`: the query itself, then every trade it
    mentions with a few of that trade's words. A query that names no trade
    comes back unchanged.
    """
    query = (query or "").strip()
    parts = [query]
    for trade in sorted(trades_in(query)):
        parts.append(_NAMES[trade])
        parts.extend(_CORE[trade])
    return " ".join(part for part in parts if part)
