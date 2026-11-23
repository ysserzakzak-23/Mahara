/// Spelling-insensitive Arabic text for client-side filtering, matching the
/// rules the backend search uses (app/utils/arabic_search.py): no diacritics
/// or tatweel, one form of alef / yaa / taa marbuta / waw, no hamza on its own.
String normalizeArabicForSearch(String input) {
  var text = input.toLowerCase();
  text = text.replaceAll(RegExp('[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED\u0640]'), '');
  const map = {
    'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
    'ى': 'ي', 'ئ': 'ي',
    'ة': 'ه',
    'ؤ': 'و',
    'ء': '',
  };
  map.forEach((from, to) => text = text.replaceAll(from, to));
  return text;
}
