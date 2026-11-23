import firebase_admin
from firebase_admin import credentials, messaging

# 1. عدّل هاد المسار لمكان ملف الـ service account عندك
cred = credentials.Certificate("firebase-service-account.json")
firebase_admin.initialize_app(cred)

# 2. حط هون الـ FCM token تبع جهازك (من قاعدة البيانات)
DEVICE_TOKEN = "flJap6nYTnCS465lcsnQEj:APA91bGIJz4baMYmhjw9pOcwiFRrhriHyrW-9Z5U9dqEzMG3-RX25pzYM3733p5HRW5t8IYhbno-X9b0fKXLNUwBj71_2znzh1cvzpnLdeUYZzhwycYwbdc"

message = messaging.Message(
    notification=messaging.Notification(
        title="اختبار إشعار",
        body="اذا شفت هاد الاشعار برا التطبيق، يبقى FCM شغال تمام",
    ),
    token=DEVICE_TOKEN,
)

try:
    response = messaging.send(message)
    print("✅ نجح الإرسال! Message ID:", response)
except Exception as e:
    print("❌ فشل الإرسال:", e)