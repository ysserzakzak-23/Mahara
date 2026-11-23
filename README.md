# مهارة — Mahara

تطبيق سوق خدمات عربي (RTL) لعرض الخدمات وحجزها وتبادلها، مع بحث دلالي بالعربية.

| الجزء | التقنية | المجلد |
|---|---|---|
| الخادم | FastAPI + PostgreSQL + SQLAlchemy | `backend_updated/` |
| التطبيق | Flutter (ويب وأندرويد) | `service_hub/` |

---

## ملفات غير موجودة هنا — وهذا مقصود

أربعة ملفات **لم تُرفع عمداً** لأنها تحتوي مفاتيح خاصة بالمشروع. لكل واحد منها نسخة `.example` بجانبه، فيها نفس البنية بقيم وهمية:

| الملف الناقص | انسخه من | ماذا يحدث بدونه |
|---|---|---|
| `backend_updated/.env` | `.env.example` | الخادم لا يقلع |
| `backend_updated/firebase-service-account.json` | — (نزّله من Firebase) | لا شيء، ما دام `FCM_ENABLED=false` |
| `service_hub/lib/firebase_options.dart` | `firebase_options.dart.example` | التطبيق **لا يُترجم** |
| `service_hub/android/app/google-services.json` | `google-services.json.example` | بناء أندرويد يفشل |

نسخ ملفات `.example` كما هي يكفي لتشغيل المشروع بالكامل. الإشعارات على الهاتف هي الميزة الوحيدة التي تحتاج مشروع Firebase حقيقياً؛ أما قائمة الإشعارات داخل التطبيق فتعمل من قاعدة البيانات في كل الأحوال.

---

## التشغيل

### الخادم

يتطلب **PostgreSQL** يعمل مسبقاً. قاعدة البيانات لا تُنشأ تلقائياً، فأنشئها أولاً:

```bash
createdb service_marketplace          # أو من psql:  CREATE DATABASE service_marketplace;
```

ثم:

```bash
cd backend_updated
python -m venv .venv && .venv/Scripts/activate      # على لينكس/ماك: source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env                                 # ثم عدّل DATABASE_URL و JWT_SECRET_KEY
alembic upgrade head
python -m scripts.seed_categories                    # ضروري: بدونه لا توجد تصنيفات ولا يعمل البحث
python -m scripts.create_admin --email admin@example.com --password "StrongPassword123" --name "Admin"
uvicorn app.main:app --reload
```

`seed_categories` ليس اختيارياً: التطبيق يبني عليه قائمة المهن، والبحث الذكي يطابق الاستعلام مع أسماء التصنيفات. بدونه تفتح الشاشات فارغة. تشغيله أكثر من مرة آمن.

التوثيق التفاعلي على `http://localhost:8000/docs`.

**قبل أي نشر حقيقي:** ولّد `JWT_SECRET_KEY` خاصاً بك. القيمة الافتراضية في `.env.example` معروفة للجميع، ومن يعرفها يستطيع تزوير جلسة دخول لأي حساب:

```bash
python -c "import secrets; print(secrets.token_urlsafe(64))"
```

### البحث الدلالي (اختياري)

ثبّت `requirements-semantic.txt` **بدل** `requirements.txt` (هو يشملها ويضيف `sentence-transformers`)، ثم اضبط `SEMANTIC_SEARCH_ENABLED=true`:

```bash
pip install -r requirements-semantic.txt
```

أول تشغيل ينزّل نموذجاً بحجم ~1.1GB ويخزّنه، فيكون إقلاع الخادم أبطأ مرة واحدة فقط. التفاصيل في `backend_updated/SEMANTIC_SEARCH_SETUP.md`. بدونه يرد البحث بالرمز 503 وبقية التطبيق يعمل.

### ملفات المتطلبات

| الملف | متى |
|---|---|
| `requirements.txt` | التشغيل العادي |
| `requirements-semantic.txt` | بدلاً من السابق، عند تفعيل البحث الدلالي |
| `requirements-dev.txt` | للتطوير والاختبارات |

### التطبيق

```bash
cd service_hub
cp lib/firebase_options.dart.example lib/firebase_options.dart
cp android/app/google-services.json.example android/app/google-services.json
flutter pub get
flutter run -d chrome        # أو: flutter run   على جهاز أندرويد
```

عنوان الخادم يُضبط في `lib/core/config/api_config.dart`. على محاكي أندرويد استخدم `10.0.2.2` بدل `localhost`.

### الاختبارات

```bash
cd backend_updated && python -m pytest -q --ignore=tests/integration_db
cd service_hub && flutter test
```

---

## ملاحظة أمنية

لا تضف `.env` ولا `firebase-service-account.json` إلى المستودع. ملف `.gitignore` في الجذر يمنعهما من كل المجلدات، لكن تحقّق بـ `git status` قبل أول رفع.
