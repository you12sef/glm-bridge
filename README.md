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
bash glm-bridge.sh --start
```

هذا كل شيء. السكريبت الموحّد يتكفل بكل التفاصيل:

1. يولّد **معرّف قناة (topic) جديداً** خاصاً بهذا التثبيت ويحفظه في الحالة
   (`~/.glm-bridge/state.env`) حيث يبقى ثابتاً عبر الإيقاف/التشغيل وإعادة
   الإقلاع
2. يجهّز الـ watchdog من القالب الموجود بجانبه ويشغّله في الخلفية
3. يضيف إعادة تشغيل تلقائية بعد إقلاع الخادم (crontab `@reboot`) **+ إشراف
   زمني كل 5 دقائق يعيد تشغيل الـ watchdog فوراً لو ماتت العملية لأي سبب**
4. **يضيف الأمر `glm-bridge` إلى PATH** (رابط في `~/.local/bin` + محاولة
   وضع رابط في `/usr/local/bin` ليصلح للأوامر غير التفاعلية أيضاً)
5. **يُنشئ يوزر AI مخصصاً تلقائياً**: `ai-<رمز عشوائي>` بكلمة مرور قوية
   مُولّدة، تُحفظ في الحالة وتُعرض في `--status` و`--handoff`، ويُضاف لـ sshd
   سطر يسمح لهذا اليوزر تحديداً بالدخول بكلمة مرور. يتطلب إنشاء اليوزر
   صلاحيات root — سيطلب منك كلمة مرور sudo أثناء التثبيت
6. ينتظر أول عنوان نفق ثم يطبع ملخصاً كهذا:

```
==========================================================
  GLM-BRIDGE IS RUNNING
----------------------------------------------------------
  Connection command : ssh -p "46085" ai-a3f9c2b1@xxxx.run.pinggy-free.link
  Current URL        : tcp://xxxx.run.pinggy-free.link:46085
  ntfy topic         : glmb-fleet-9b1154b018a3
  Project            : /home/you/glm-bridge
  State dir          : /home/you/.glm-bridge
----------------------------------------------------------
  Dedicated AI user  : ai-a3f9c2b1  (password auth)
  AI password        : Xk7bT2mQ9rVz
  Sudo               : off  (security enforced by this user's OS permissions)
  The password is also shown by: glm-bridge --status | --handoff
----------------------------------------------------------
  From any directory :  glm-bridge --status
  Stop               :  glm-bridge --stop
  Help               :  glm-bridge --help
==========================================================
```

> كل مخرجات السكريبت في الترمينل **بالإنجليزية** لتعمل على أي خادم، بينما
> التوثيق (هذا الملف) عربي أولاً. The username in the connection command is
> the auto-created `ai-<random>` user — not the owner's account.

## الخطوة الأخيرة: أعطِ المعلومات لمساعدك الذكي

شغّل `glm-bridge --handoff` على الخادم — يطبع لك **فقط** الأسطر الجاهزة
للّصق مباشرة في الشات:

```text
=== GLM-BRIDGE AI HANDOFF ===
ntfy topic   : glmb-fleet-9b1154b018a3
AI username  : ai-a3f9c2b1
AI password  : Xk7bT2mQ9rVz
=============================
```

أرسلها لمساعدك في **الشات** (وهي نفسها تُطبع في نهاية `--status`). سيسحب
المساعد العنوان الحالي من القناة، يتصل بالخادم بهذا اليوزر وكلمة المرور،
ويرد عليك: `READY — bridge verified on <server>, awaiting orders`.

> **مهم:** المعرّف محفوظ ويبقى ثابتاً عبر الإيقاف والتشغيل (`--stop` ثم
> `--start`) ويعود تلقائياً بعد إعادة إقلاع الخادم. يتغير فقط بـ
> `glm-bridge --new-topic` أو بعد `--uninstall` — عندها أرسل المعرّف الجديد
> لمساعدك في الشات.
>
> **مهم أيضاً:** كلمة مرور يوزر الـ AI تُقرأ في أي لحظة من `--status` أو
> `--handoff` — لا حاجة لحفظها في أي ملف، ويمكن تدويرها بأمر واحد
> (`--ai-user rotate`).

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
| `glm-bridge.sh` | **السكريبت الموحّد**: `--start` تثبيت وتشغيل، `--stop` إيقاف، `--status`، `--restart`، `--new-topic`، `--uninstall`/`--purge` — يضيف الأمر `glm-bridge` إلى PATH، ويدير يوزر AI مخصص: `--ai-user` و`--ai-sudo`، ويسجّل كل عملية في `bridge.log` | الخادم |
| `bridge/glm-watchdog.sh` | قالب البرنامج الدائم: يجدد النفق كل 50 دقيقة، نبضة كل 5 دقائق، ينشر العنوان في القناة، يسجّل خروجه وفشل النشر، ويقلّم سجلاته بنفسه | الخادم |
| `bridge/glm-bootstrap.sh` | مُثبّت بديل يستخدمه الـ AI عن بُعد (يأخذ الـ topic كوسيطة، يكتب `state.env`، ويجد القالب بجانبه) | الخادم |
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
│ • cron يعيد تشغيله لو مات   │           │                           │
└─────────────────────────────┘           └───────────────────────────┘
```

رسائل القناة نوعان: `RENEW` (عنوان جديد بعد كل تجديد) و`HEARTBEAT` (نبضة حياة
كل 5 دقائق). الأخيرة تكفي وحدها ليعرف المساعد أن الخادم حي والعنوان صالح.

## الأمان باختصار

- **يوزر AI مخصص بكلمة مرور** — حسابك الشخصي (`admin`) وكلمة مروره لا يلمسهما
  الـ AI أبداً. كلمة مرور يوزر الـ AI مُولّدة عشوائياً، تُحفظ في
  `~/.glm-bridge/ai-user.env` (صلاحية 600 — يقرأها مالك الخادم فقط)، وتُعرض
  في `--status`/`--handoff` لتلصقها في الشات.
- **الأمان من صلاحيات اليوزر نفسه، لا من ملفات مفاتيح** — اليوزر لا يملك
  sudo افتراضياً، shell عادي محصور بصلاحياته، وكل دخول يُسجّل في `auth.log`
  و`last` و`bridge.log`. سطر صريح في sshd يسمح لهذا اليوزر تحديداً بكلمة
  مرور (`/etc/ssh/sshd_config.d/glm-bridge-ai.conf`) فلا يتأثر لو شدّدت
  الإعدادات العامة لاحقاً.
- **إلغاء فوري في أي لحظة**: `--ai-user lock` يحجب الدخول فوراً،
  `--ai-user remove` يحذف اليوزر ومجلده، `--ai-user rotate` يغيّر كلمة
  المرور بضغطة واحدة (الجديدة تظهر في `--status`).
- معرّف القناة يُعامل كسرّ خفيف: من يعرفه يرى عناوين النفق فقط — اتصال SSH
  نفسه مشفّر من الطرف للطرف، والمرحّل (pinggy) يرى نصاً مشفراً لا أكثر.
- التثبيت الجديد يولّد معرّفاً جديداً + يوزر AI جديداً بكلمة مرور جديدة.
  يمكن تدوير المعرّف بـ `glm-bridge --new-topic` (القديم يموت).

## السجلات — كل شيء مكتوب

| السجل | ماذا يحتوي | مَن يكتبه |
|-------|-----------|-----------|
| `~/.glm-bridge/watchdog.log` | نبضات، تجديدات، أخطاء النشر (مع كود HTTP)، سبب كل خروج للـ watchdog | watchdog |
| `~/.glm-bridge/bridge.log` | كل عملية إدارية: start/stop/rotate/lock/remove… مع الطابع الزمني والمستخدم | glm-bridge |
| `~/.glm-bridge/current.json` | آخر عنوان نفق + وقت التجديد | watchdog |
| `~/.glm-bridge/CONNECT.txt` | ملخص الاتصال الحالي (يُحدَّث مع كل `--start`) | glm-bridge |
| `~/.glm-bridge/state.env` | `NTFY_TOPIC` + `SERVER_NAME` — مصدر الحقيقة للمعرّف | glm-bridge / bootstrap |

السجلات تُقلَّم تلقائياً (`watchdog.log` فوق 2MB يُقص لآخر 1000 سطر،
`bridge.log` فوق 512KB لآخر 500 سطر) — لا تنمو بلا حدود.

## المتطلبات

- **الخادم**: أوبونتو/ديبيان أو مشابه، مع `bash` و`ssh` و`sed` و(`openssl`
  أو `/dev/urandom`). بدون root (عدا إنشاء يوزر الـ AI — عبر sudo مرة واحدة).
- **بيئة الـ AI**: بايثون 3 + `pip install paramiko` + وصول HTTPS إلى ntfy.sh

## مشاكل شائعة؟

| المشكلة | الحل |
|---------|------|
| لا يظهر عنوان بعد التثبيت | انظر `~/.glm-bridge/watchdog.log` و`tunnel_new.log` |
| القناة لا تعرض أي رسائل | الـ watchdog متوقف أو الخادم بلا إنترنت — `glm-bridge --status` ثم `glm-bridge --restart`. لو ماتت العملية، إشراف الـ cron يعيدها خلال ≤5 دقائق تلقائياً |
| سبب موت الـ watchdog غير معروف | لم يعد مجهولاً: `watchdog.log` يسجّل سبب كل خروج (`watchdog exiting — reason: ...`) |
| غيّرت المعرّف فانقطع اتصال الـ AI | طبيعي — المعرّف الجديد يلغي القديم. أرسل المعرّف الجديد له في الشات (`--new-topic`) |
| أُعيد تشغيل الخادم | crontab `@reboot` يعيد تشغيل الـ watchdog تلقائياً خلال دقيقتين، ثم تصله الرسائل كالعادة |
| `glm-bridge` غير موجود في أمر غير تفاعلي | السكريبت يضع رابطاً في `/usr/local/bin` أيضاً؛ أو استخدم المسار الكامل `bash ~/glm-bridge/glm-bridge.sh --status` |

## إدارة المشروع — ملف واحد لكل شيء

كل العمليات تتم عبر سكريبت واحد، وبعد أول `--start` يُضاف الأمر `glm-bridge`
إلى PATH فتعمل من أي مجلد:

| الأمر | الوظيفة |
|-------|---------|
| `bash glm-bridge.sh --start` | تثبيت (أول مرة) + تشغيل |
| `glm-bridge --stop` | إيقاف كامل: watchdog + نفق + التشغيل التلقائي |
| `glm-bridge --status` | عرض الحالة + كلمة مرور الـ AI + قسم **handoff snippet** |
| `glm-bridge --handoff` | **اطبع فقط القسم الجاهز للّصق في الشات للـ AI** |
| `glm-bridge --restart` | إعادة تشغيل |
| `glm-bridge --new-topic` | معرّف جديد وإعادة تشغيل — أخبر مساعدك فوراً |
| `glm-bridge --uninstall` | إيقاف + إزالة الاندماج (cron + PATH + الحالة)، ويبقي مجلد المشروع |
| `glm-bridge --purge` | مثل `--uninstall` + حذف مجلد المشروع |

## حساب AI مخصص (تلقائي)

`--start` **يُنشئ يوزر AI مخصصاً تلقائياً** عند التثبيت الأول — لا تحتاج
لتنفيذ أي أمر إضافي. اليوزر يكون باسم `ai-<رمز عشوائي>`، بكلمة مرور قوية
مُولّدة، ويُضاف له سطر صريح في sshd يسمح له بالدخول بكلمة مروره.

### المبدأ المعماري: كلمة مرور + صلاحيات نظام التشغيل

```
بيئة الـ AI (أي شات)                      الخادم
┌────────────────────────────────┐        ┌───────────────────────────────┐
│ يقرأ من الشات:                 │        │ ai-<rand> (يوزر OS عادي)      │
│   AI username + AI password    │──SSH───▶   لا sudo (افتراضياً)         │
│ (الملصق يأتي من --handoff)     │        │ sshd: Match User ai-<rand>    │
└────────────────────────────────┘        │   PasswordAuthentication yes  │
                                          │ ~/.glm-bridge/ai-user.env 600 │
                                          │   ↳ AI_PASS (يقرأه المالك)   │
                                          └───────────────────────────────┘
```

**لماذا هذا التصميم؟**
- **عزل كامل لحسابك الشخصي** — كلمة مرورك أنت لا تُرسل في أي شات أبداً
- **كلمة مرور الـ AI قابلة للعرض والتدوير** — تظهر في `--status`/`--handoff`
  في أي لحظة، وتتغير بأمر واحد، فلا يوجد سرّ "يضيع" ولا يعطّل الاتصال
- **سياسة الأمان = صلاحيات اليوزر نفسه** — لا sudo افتراضياً، أي أمر خطر
  يحتاج تفويضاً صريحاً منك، وكل جلسة تُسجّل باسمه في سجلات النظام
- **تدقيق كامل** — `bridge.log` للعمليات الإدارية، `auth.log`/`last` للدخول،
  و`watchdog.log` لحالة الجسر وسبب أي خروج

### الأوامر

```bash
# يتم تلقائياً عند --start (لا تحتاج لتنفيذها يدوياً):
#   - إنشاء يوزر ai-<rand> بكلمة مرور مولّدة
#   - حفظ اليوزر وكلمة المرور في الحالة (ai-user.env، صلاحية 600)
#   - سماح صريح في sshd لهذا اليوزر بكلمة المرور

glm-bridge --status                # عرض كل المعلومات (اليوزر، كلمة المرور، sudo، آخر دخول، الإشراف)
glm-bridge --handoff               # الملصق الجاهز للشات (topic + username + password)
glm-bridge --ai-user status        # تفاصيل اليوزر + كلمة المرور الحالية
glm-bridge --ai-user rotate        # كلمة مرور جديدة (تُحفظ وتُعرض في status)
glm-bridge --ai-user lock          # حجب فوري لوصول الـ AI (unlock للرجوع)
glm-bridge --ai-user remove        # حذف اليوزر ومجلده نهائياً
glm-bridge --ai-sudo on|off        # منح/سحب صلاحيات sudo — خيار صريح وصاخب

# الإعداد اليدوي الكامل (إن فشل التلقائي لأي سبب):
glm-bridge --ai-user create
```

الأوامر التي تحتاج root تعيد تشغيل نفسها عبر `sudo` — تدخل كلمة sudo **أنت**
في الطرفية، ولا شيء منها يمر عبر الـ AI.

> **ملاحظة:** `sudo` لليوزر نفسه تعمل بكلمة مروره عند تفعيلها بـ
> `--ai-sudo on` — لكن التوجيه الدائم هو أن تبقى OFF، وأن تمرّر أي أمر
> يحتاج root عبر حلقة الموافقة في `AI-HANDOFF.md` §10، فتنفذه أنت (أو
> تعطي sudo مؤقتاً ثم تسحبه).

---

# glm-bridge (English)

A tiny, root-free bridge that keeps your AI assistant connected to a NAT'd
server even though the free pinggy tunnel address rotates every ~60 minutes.

## How it works

A watchdog daemon opens an outbound pinggy tunnel exposing the server's own
SSH, renews it every 50 minutes, and publishes the current `tcp://host:port`
to your private ntfy.sh topic (`RENEW` after each renewal, `HEARTBEAT` every
5 minutes). Any AI that knows the topic reads the latest message, connects
over SSH, and starts working — no VPN, no ZeroTier, no root. A `@reboot`
crontab entry plus a `*/5` supervision entry restart the watchdog whenever
the process dies (and the watchdog logs the reason of every exit itself).

## Quick start

```bash
# copy the whole project folder to the server (once), then from inside it:
bash glm-bridge.sh --start
```

The script generates a **fresh ntfy topic id** and persists it in
`~/.glm-bridge/state.env`, renders the watchdog from the local template,
starts it detached, installs both crontab entries (`@reboot` + `*/5`
supervision), adds the `glm-bridge` command to your PATH (`~/.local/bin` and,
best-effort, `/usr/local/bin` so non-interactive SSH commands find it too),
**auto-creates a dedicated AI user `ai-<random>` with a generated password**
(stored in `~/.glm-bridge/ai-user.env`, mode 600, and displayed by
`--status`/`--handoff`; an explicit sshd rule allows password auth for that
user — sudo is prompted for the useradd step), waits for the first tunnel
URL, and prints the connection command **plus the new topic**.

Then run `glm-bridge --handoff` and paste its snippet to your AI **in the
chat**: the topic, the AI username and the AI password. The AI discovers the
live URL from the topic, connects with paramiko using that username +
password, and replies `READY — awaiting orders`.

## Good to know

- **The topic persists across `--stop` / `--start` cycles AND server
  reboots** (stored in `~/.glm-bridge/state.env`). It only changes with
  `glm-bridge --new-topic` or after `--uninstall` — then send the new topic
  to your AI in the chat.
- One-file management: `glm-bridge --start | --stop | --status | --restart |
  --new-topic | --uninstall | --purge` — works from any directory after the
  first `--start`. `--uninstall` keeps the project folder; `--purge` deletes
  it too.
- **Dedicated AI user — automatic, password-based**: `--start` auto-creates
  an `ai-<random>` OS user with a generated password. The password lives in
  `~/.glm-bridge/ai-user.env` (mode 600) and is displayed by `--status`,
  `--handoff` and the `--start` summary — paste it to your AI in the chat.
  Security policy is enforced by the user's own OS permissions: no sudo by
  default, instant `lock`/`remove`/`rotate`, every login auditable via
  `last`/`auth.log`.
  - `--status` shows: service state, current URL, topic, supervision state,
    AI username, AI password, sudo state, last login.
  - `--ai-sudo on|off` (explicit full-sudo toggle, loud warning, no NOPASSWD).
  - `--ai-user create|status|rotate|lock|unlock|remove` for full control.
  - Root-needing actions re-run themselves via sudo when YOU call them.
- **Logging is complete**: `watchdog.log` (heartbeats, renewals, publish
  failures with HTTP code, exit reason of every watchdog death),
  `bridge.log` (every manager action, timestamped), `current.json`,
  `CONNECT.txt`, `state.env`. Logs self-trim so they never grow unbounded.
- `bridge/glm-bootstrap.sh` is the AI-driven alternative installer (it takes
  the topic as an argument, writes `state.env`, and finds the template next
  to itself), and `bridge/discover.py` lists live servers / connects /
  remote-installs from the AI sandbox.

## Requirements

- **Server**: Ubuntu/Debian-like with `bash`, `ssh`, `sed`, and `openssl`
  (or `/dev/urandom`). No root for the bridge itself; sudo once for the
  AI-user creation.
- **AI sandbox**: Python 3, `pip install paramiko`, outbound HTTPS to ntfy.sh.
