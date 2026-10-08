# glm-bridge 🌉

**جسر وصول دائم لمساعدك الذكي إلى خادمك — حتى لو كان خلف NAT وبتغيّر العنوان كل ساعة.**

خادم منزلي أو VPS خلف جدار NAT؟ لا تملك IP عام؟ تريد أن يتصل بك مساعدك الذكي
ويشغّل الأوامر متى احتاج؟ هذا المشروع صُمم لهذه الحالة بالضبط — بدون صلاحيات
root، وبدون أدوات شبكة معقدة.

---

## الفكرة في سطرين

نفق **pinggy** المجاني يفتح باباً مؤقتاً لـ SSH على خادمك، لكن عنوانه يتغير كل
~60 دقيقة. سكريبت مراقبة صغير (**watchdog**) يجدد النفق كل 50 دقيقة وينشر
العنوان الجديد تلقائياً في قناة إشعارات **ntfy.sh** خاصة بك. أي مساعد AI يعرف
اسم القناة يقرأ العنوان الحالي في أي لحظة ويتصل مباشرة — لا VPN، لا ZeroTier،
لا صلاحيات root، ولا حتى أن تكون أنت متصلاً.

## البداية السريعة (على الخادم)

المشروع **متكامل ومحلي بالكامل** — لا يحتاج GitHub ولا أي تنزيلات وقت التثبيت:

```bash
# 1) انسخ مجلد المشروع كاملاً إلى خادمك (scp أو SFTP أو git clone — مرة واحدة)
# 2) من داخل المجلد:
bash install.sh                # أو: bash install.sh اسم-الخادم
```

هذا كل شيء. المُثبّت يتكفل بكل التفاصيل:

1. يولّد **معرّف قناة (topic) جديداً** خاصاً بهذا التثبيت
2. يجهّز الـ watchdog من القالب الموجود بجانبه ويشغّله في الخلفية
3. يضيف إعادة تشغيل تلقائية بعد إقلاع الخادم (crontab `@reboot`)
4. ينتظر أول عنوان نفق ثم يطبع ملخصاً كهذا:

```
==========================================================
  GLM-BRIDGE INSTALLED OK
----------------------------------------------------------
  Connection command:
    ssh -p "46085" admin@xxxx.run.pinggy-free.link

  Tunnel URL : tcp://xxxx.run.pinggy-free.link:46085
  ntfy topic : glmb-fleet-9b1154b018a3   <- FRESH topic for THIS install
  Project    : /home/you/glm-bridge (fully local — no GitHub needed)
  State dir  : /home/you/.glm-bridge
==========================================================
```

## الخطوة الأخيرة: أعطِ المعلومات لمساعدك الذكي

افتح **`AI-HANDOFF.md`** لترى ماذا يحتاج أي مساعد AI، ثم أرسل له في **الشات**:

- معرّف القناة الجديد `glmb-fleet-...` (المطبوع في ملخص التثبيت)
- اسم المستخدم وكلمة المرور للـ SSH — **كلمة المرور تبقى في الشات فقط، ولا
  تُكتب في أي ملف أبداً**

سيسحب المساعد العنوان الحالي من القناة، يتصل بالخادم، ويرد عليك:
`READY — bridge verified on <server>, awaiting orders`

> **مهم:** كل تشغيل لـ `install.sh` يولّد معرّف قناة جديداً. إن أعدت التثبيت،
> أرسل المعرّف الجديد لمساعدك في الشات — المعرف القديم لن يعمل بعد ذلك.

## التواصل عبر الإشعارات (وسيلة… وليست الغاية)

قناة ntfy ليست فقط لنشر العناوين — إنها خط تواصل مباشر بينك وبين مساعدك:

- يستطيع المساعد **أن يطلب إذنك** قبل أي تعديل ("أُنشئ ملف تجربة؟") وتوافق
  بضغطة من تطبيق ntfy
- يبلّغك **بنتائج كل خطوة** فور حدوثها دون أن تسأل
- تستطيع أنت **إرسال أوامر قصيرة** عبر الإشعار أثناء عمله

لكن تذكّر الفلسفة: **المهمة الحقيقية تُعطى في الشات** — برمجة، إصلاح مشكلة،
بناء بيئة تشغيل، نشر خدمة... الإشعارات مجرد وسيلة تواصل سريعة أثناء تنفيذ
المهمة. التفاصيل الكاملة للبروتوكول موثقة في `AI-HANDOFF.md` §10.

## ملفات المشروع

| الملف | ماذا يفعل | أين يعمل |
|------|-----------|----------|
| `install.sh` | المُثبّت: يولّد topic جديداً، يجهّز الـ watchdog من القالب المحلي، يشغّله، يطبع ملخص الاتصال | الخادم |
| `bridge/glm-watchdog.sh` | قالب البرنامج الدائم: يجدد النفق كل 50 دقيقة، نبضة كل 5 دقائق، ينشر العنوان في القناة | الخادم |
| `bridge/glm-bootstrap.sh` | مُثبّت بديل يستخدمه الـ AI عن بُعد (يأخذ الـ topic كوسيطة، ويجد القالب بجانبه) | الخادم |
| `bridge/discover.py` | أداة اختيارية: سرد الخوادم الحية / اتصال وتنفيذ / تثبيت عن بُعد | بيئة الـ AI |
| `AI-HANDOFF.md` | **الملف الوحيد الذي تعطيه لأي AI** ليفهم كل البروتوكول والمزالق | الشات |
| `README.md` | هذا الملف | — |

## كيف يعمل؟

```
الخادم (خلف NAT)                          بيئة الـ AI (أي شات)
┌─────────────────────────────┐           ┌───────────────────────────┐
│ glm-watchdog.sh (بدون root) │           │ يقرأ القناة ← العنوان     │
│ • يفتح نفق pinggy للـ SSH   │──ntfy.sh──▶  الحالي tcp://host:port   │
│ • يجدده كل 50 دقيقة         │           │ يتصل عبر SSH (paramiko)   │
│ • نبضة كل 5 دقائق           │◀──ntfy.sh─│ ينفذ ويردّ عليك بالإشعار  │
│ • ينشر العنوان الحالي       │           │ جاهز للأوامر              │
└─────────────────────────────┘           └───────────────────────────┘
```

رسائل القناة نوعان: `RENEW` (عنوان جديد بعد كل تجديد) و`HEARTBEAT` (نبضة حياة
كل 5 دقائق). الأخيرة تكفي وحدها ليعرف المساعد أن الخادم حي والعنوان صالح.

## الأمان باختصار

- **كلمة مرور SSH لا تُكتب في أي ملف** — تُرسل في الشات فقط، وغيّرها بأمر
  `passwd` بعد انتهاء المشروع
- معرّف القناة يُعامل كسرّ خفيف: من يعرفه يرى عناوين النفق فقط — اتصال SSH
  نفسه مشفّر من الطرف للطرف، والمرحّل (pinggy) يرى نصاً مشفراً لا أكثر
- كل تثبيت جديد يولّد معرّفاً جديداً، فحتى لو تسرب معرّف قديم فإن نافذة
  صلاحيته قصيرة

## المتطلبات

- **الخادم**: أوبونتو/ديبيان أو مشابه، مع `bash` و`ssh` و`sed` و(`openssl`
  أو `/dev/urandom`). بدون root.
- **بيئة الـ AI**: بايثون 3 + `pip install paramiko` + وصول HTTPS إلى ntfy.sh

## مشاكل شائعة؟

| المشكلة | الحل |
|---------|------|
| لا يظهر عنوان بعد التثبيت | انظر `~/.glm-bridge/watchdog.log` و`tunnel_new.log` |
| القناة لا تعرض أي رسائل | الـ watchdog متوقف أو الخادم بلا إنترنت — اتصل بأمر الاتصال الاحتياطي من ملخص التثبيت، ثم أعد `bash install.sh` |
| أعدت التثبيت فانقطع اتصال الـ AI | طبيعي — المعرف الجديد يلغي القديم. أرسل المعرّف الجديد له في الشات |
| أُعيد تشغيل الخادم | crontab `@reboot` يعيد تشغيل الـ watchdog تلقائياً خلال دقيقتين، ثم تصله الرسائل كالعادة |

---

# glm-bridge (English)

A tiny, root-free bridge that keeps your AI assistant connected to a NAT'd
server even though the free pinggy tunnel address rotates every ~60 minutes.

## How it works

A watchdog daemon opens an outbound pinggy tunnel exposing the server's own
SSH, renews it every 50 minutes, and publishes the current `tcp://host:port`
to your private ntfy.sh topic (`RENEW` after each renewal, `HEARTBEAT` every
5 minutes). Any AI that knows the topic reads the latest message, connects
over SSH, and starts working — no VPN, no ZeroTier, no root.

## Quick start

```bash
# copy the whole project folder to the server (once), then from inside it:
bash install.sh [server-name]
```

The installer generates a **fresh ntfy topic id** for this install, renders
the watchdog from the local template, starts it detached, installs a `@reboot`
crontab entry, waits for the first tunnel URL, and prints the connection
command **plus the new topic**.

Then send your AI **in the chat**: the new topic, the SSH username, and the
password (chat only — never stored in any file). The AI discovers the live
URL, connects, and replies `READY — awaiting orders`.

## Good to know

- **Every `install.sh` run creates a new topic.** Re-installing? Send the new
  topic to your AI in the chat — the old one stops working.
- The two-way **notification/approval bridge** (ask permission, report
  results, receive short commands) is fully documented for the AI in
  **`AI-HANDOFF.md`** §10. Remember the philosophy: notifications are a
  *means* — the mission itself arrives in the chat.
- `bridge/glm-bootstrap.sh` is the AI-driven alternative installer (it takes
  the topic as an argument and finds the template next to itself), and
  `bridge/discover.py` lists live servers / connects / remote-installs from
  the AI sandbox.

## Requirements

- **Server**: Ubuntu/Debian-like with `bash`, `ssh`, `sed`, and `openssl`
  (or `/dev/urandom`). No root.
- **AI sandbox**: Python 3, `pip install paramiko`, outbound HTTPS to ntfy.sh.
