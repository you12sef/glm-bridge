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
2. يجهّز الـ watchdog من القالب الموجود بجانبه ويشغّله في الخلفية
3. يضيف إعادة تشغيل تلقائية بعد إقلاع الخادم (crontab `@reboot`)
4. **يضيف الأمر `glm-bridge` إلى PATH** — من بعدها تشغّل/توقف المشروع من أي مجلد
5. **(v2.3) يُنشئ يوزر AI مخصصاً تلقائياً**: `ai-<رمز عشوائي>` بدون كلمة مرور،
   ويُولّد زوج مفاتيح ed25519 في الـ sandbox المحلي، ويثبّت المفتاح العام فقط
   على الخادم، ويفعّل وضع key-only (sshd يرفض كلمات المرور لهذا اليوزر).
   يتطلب إنشاء اليوزر صلاحيات root — سيطلب منك كلمة مرور sudo أثناء التثبيت.
6. ينتظر أول عنوان نفق ثم يطبع ملخصاً كهذا:

```
==========================================================
  GLM-BRIDGE IS RUNNING
----------------------------------------------------------
  Connection command : ssh -i ~/.glm_keys/ai-key -p "46085" ai-a3f9c2b1@xxxx.run.pinggy-free.link
  Current URL        : tcp://xxxx.run.pinggy-free.link:46085
  ntfy topic         : glmb-fleet-9b1154b018a3
  Project            : /home/you/glm-bridge
  State dir          : /home/you/.glm-bridge
----------------------------------------------------------
  Dedicated AI user    : ai-a3f9c2b1  (key-based auth)
  Private key (sandbox): ~/.glm_keys/ai-key
  Key fingerprint      : SHA256:xxxxxx (ED25519)
  Auth mode            : key-only=on, sudo=off
----------------------------------------------------------
  From any directory :  glm-bridge --status
  Stop               :  glm-bridge --stop
  Help               :  glm-bridge --help
==========================================================
```

> كل مخرجات السكريبت في الترمينل **بالإنجليزية** لتعمل على أي خادم، بينما
> التوثيق (هذا الملف) عربي أولاً. The username in the connection command is
> the auto-created `ai-<random>` user (v2.3) — not the owner's account.

## الخطوة الأخيرة: أعطِ المعلومات لمساعدك الذكي

افتح **`AI-HANDOFF.md`** لترى ماذا يحتاج أي مساعد AI، ثم أرسل له في **الشات**:

- معرّف القناة الجديد `glmb-fleet-...` (المطبوع في ملخص التثبيت)
- اسم يوزر الـ AI `ai-<رمز>` (المُنشأ تلقائياً — وليس حسابك الشخصي)
- **لا حاجة لكلمة مرور بعد الآن** — الاتصال يتم بالمفتاح الخاص في الـ sandbox
  عند `~/.glm_keys/ai-key`. المفتاح العام فقط على الخادم.

> **(v2.3) لتسريع النسخ:** شغّل `glm-bridge --handoff` على الخادم — سيطبع لك
> **فقط** الأسطر الأربعة الجاهزة للّصق مباشرة في الشات للـ AI (topic + AI username
> + key fingerprint + key path). بدون PID، بدون uptime، بدون ضجيج.
> إن كنت على الجهاز المحلي (وليس SSH remote) يحاول نسخها للحافظة تلقائياً.

سيسحب المساعد العنوان الحالي من القناة، يفحص أنّ المفتاح الخاص موجود في
sandbox لديه (إن لم يوجد يولّده ويطلب منك تثبيت العام — انظر `AI-HANDOFF.md` §11.1)،
ثم يتصل بالخادم ويرد عليك:
`READY — bridge verified on <server>, awaiting orders`

> **مهم:** المعرّف محفوظ ويبقى ثابتاً عبر الإيقاف والتشغيل (`--stop` ثم
> `--start`). يتغير فقط بـ `glm-bridge --new-topic` أو بعد `--uninstall` —
> عندها أرسل المعرّف الجديد لمساعدك في الشات.
>
> **مهم أيضاً (v2.3):** المفتاح الخاص يُولَّد مرة واحدة في الـ sandbox ويبقى
> ثابتاً عبر جلسات الـ AI المتعددة. لا حاجة لتوليد مفتاح جديد في كل جلسة —
> اقرأ `AI-HANDOFF.md` §11.1 أولاً.

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
| `glm-bridge.sh` | **السكريبت الموحّد**: `--start` تثبيت وتشغيل، `--stop` إيقاف، `--status`، `--restart`، `--new-topic`، `--uninstall`/`--purge` — يضيف الأمر `glm-bridge` إلى PATH، ويدير يوزر AI مخصص: `--ai-user` و`--ai-sudo` و`--ai-key` | الخادم |
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

- **(v2.3) لا توجد كلمة مرور أصلاً** — يوزر الـ AI يُنشأ بدون كلمة مرور،
  والاتصال يتم بالمفتاح فقط. sshd يرفض أي محاولة بكلمة مرور لليوزر.
- **(v2.3) المفتاح الخاص في الـ sandbox فقط** — لا يغادر بيئة الـ AI أبداً.
  الخادم يحتفظ بالمفتاح العام فقط، فاختراق الخادم لا يكشف أي سرّ.
- حسابك الشخصي (`admin`) وكلمة مروره تبقى كاحتياط — غيّرها بأمر `passwd`
  بعد انتهاء المشروع.
- معرّف القناة يُعامل كسرّ خفيف: من يعرفه يرى عناوين النفق فقط — اتصال SSH
  نفسه مشفّر من الطرف للطرف، والمرحّل (pinggy) يرى نصاً مشفراً لا أكثر.
- التثبيت الجديد يولّد معرّفاً جديداً + يوزر AI جديد + مفتاح ed25519 جديد.
  يمكن تدوير المعرّف بـ `glm-bridge --new-topic` (القديم يموت)، وتدوير
  المفتاح بحذفه في sandbox وتوليد واحد جديد.

## المتطلبات

- **الخادم**: أوبونتو/ديبيان أو مشابه، مع `bash` و`ssh` و`sed` و(`openssl`
  أو `/dev/urandom`). بدون root.
- **بيئة الـ AI**: بايثون 3 + `pip install paramiko` + وصول HTTPS إلى ntfy.sh

## مشاكل شائعة؟

| المشكلة | الحل |
|---------|------|
| لا يظهر عنوان بعد التثبيت | انظر `~/.glm-bridge/watchdog.log` و`tunnel_new.log` |
| القناة لا تعرض أي رسائل | الـ watchdog متوقف أو الخادم بلا إنترنت — `glm-bridge --status` ثم `glm-bridge --restart`، وإن لزم اتصل بأمر الاتصال الاحتياطي |
| غيّرت المعرّف فانقطع اتصال الـ AI | طبيعي — المعرّف الجديد يلغي القديم. أرسل المعرّف الجديد له في الشات (`--new-topic`) |
| أُعيد تشغيل الخادم | crontab `@reboot` يعيد تشغيل الـ watchdog تلقائياً خلال دقيقتين، ثم تصله الرسائل كالعادة |

## إدارة المشروع — ملف واحد لكل شيء

كل العمليات تتم عبر سكريبت واحد، وبعد أول `--start` يُضاف الأمر `glm-bridge`
إلى PATH فتعمل من أي مجلد:

| الأمر | الوظيفة |
|-------|---------|
| `bash glm-bridge.sh --start` | تثبيت (أول مرة) + تشغيل |
| `glm-bridge --stop` | إيقاف كامل: watchdog + نفق + التشغيل التلقائي |
| `glm-bridge --status` | عرض الحالة + قسم **handoff snippet** في النهاية |
| `glm-bridge --handoff` | **اطبع فقط القسم الجاهز للّصق في الشات للـ AI** (بدون PID/uptime/sudo) |
| `glm-bridge --restart` | إعادة تشغيل |
| `glm-bridge --new-topic` | معرّف جديد وإعادة تشغيل — أخبر مساعدك فوراً |
| `glm-bridge --uninstall` | إيقاف + إزالة الاندماج (cron + PATH + الحالة)، ويبقي مجلد المشروع |
| `glm-bridge --purge` | مثل `--uninstall` + حذف مجلد المشروع |

> **مهم:** معرّف القناة محفوظ في `~/.glm-bridge/state.env` ويبقى ثابتاً عبر
> `--stop` ثم `--start` — تواصلك مع مساعدك لن ينقطع. يتغير فقط مع
> `--new-topic` أو بعد `--uninstall`، وعندها أرسل المعرّف الجديد في الشات.

## حساب AI مخصص (تلقائي منذ v2.3)

منذ v2.3، `--start` **يُنشئ يوزر AI مخصصاً تلقائياً** عند التثبيت الأول — لا
تحتاج لتنفيذ أي أمر إضافي. اليوزر يكون باسم `ai-<رمز عشوائي>`، **بدون كلمة
مرور** (مقفول من البداية)، ويتصل حصراً عبر مفتاح ed25519.

### المبدأ المعماري (v2.3): المفتاح الخاص في الـ sandbox، العام على الخادم

```
بيئة الـ AI (sandbox)                     الخادم
┌────────────────────────────────┐        ┌───────────────────────────────┐
│ ~/.glm_keys/ai-key             │        │ /home/ai-<rand>/               │
│   ↳ المفتاح الخاص (لا يغادر) │        │   .ssh/authorized_keys         │
│ ~/.glm_keys/ai-key.pub         │───SFTP─▶   ↳ المفتاح العام فقط        │
│   ↳ المفتاح العام (يُرفع)     │        │ sshd: Match User ai-*          │
└────────────────────────────────┘        │   PasswordAuthentication no   │
                                          └───────────────────────────────┘
```

**لماذا هذا التصميم؟**
- **لا كلمة مرور في الشات** — لا تسريب ممكن، لا تخمين ممكن
- **كل جلسة AI جديدة تجد المفتاح جاهزاً** في `~/.glm_keys/ai-key` فلا تحتاج
  لتوليد مفتاح جديد ولا تنتظر تثبيت المفتاح من المالك
- **اختراق الخادم لا يكشف المفتاح الخاص** — المفتاح العام فقط على الخادم
- **التدوير سهل**: احذف المفتاح في sandbox، ولّد واحداً جديداً، اطلب من
  المالك تثبيت `.pub` الجديد

### الأوامر (للإدارة اليدوية بعد التثبيت التلقائي)

```bash
# يتم تلقائياً عند --start (لا تحتاج لتنفيذها يدوياً):
#   - إنشاء يوزر ai-<rand> بدون كلمة مرور
#   - توليد زوج مفاتيح ed25519 في sandbox
#   - رفع المفتاح العام للخادم
#   - تفعيل key-only (sshd يرفض كلمات المرور لليوزر)

glm-bridge --status                # عرض كل المعلومات (اليوزر، البصمة، مسار المفتاح، sudo، آخر دخول)
glm-bridge --ai-user status        # تفاصيل اليوزر: sudo، المفاتيح، القفل
glm-bridge --ai-user lock          # حجب فوري لوصول الـ AI (unlock للرجوع)
glm-bridge --ai-user remove        # حذف اليوزر ومجلده نهائياً
glm-bridge --ai-sudo on|off        # منح/سحب صلاحيات sudo — خيار صريح وصاخب
glm-bridge --ai-key add key.pub    # تثبيت مفتاح عام إضافي
glm-bridge --ai-key list           # عرض المفاتيح والبصمات
glm-bridge --ai-key revoke <بصمة>  # إلغاء مفتاح فوراً
glm-bridge --ai-user key-only on|off  # تبديل وضع المفتاح فقط

# الإعداد اليدوي الكامل (إن فشل التلقائي لأي سبب):
sudo bash glm-bridge.sh --ai-auto-install /tmp/pubkey.pub
```

### ماذا يحقق هذا؟

- **عزل الاعتماديات** — كلمة مرورك الشخصية لا تلمس الشات أبداً
- **تدقيق كامل** — كل فعل للـ AI يُسجّل باسمه في `auth.log` و`last`
- **تحكم صريح** — sudo معطّلة افتراضياً، وتفعيلها يطبع تحذيراً كبيراً، وسحبها
  بأمر واحد. لا NOPASSWD: أوامر sudo تتطلب كلمة مرور اليوزر نفسه (لكن بما
  أنّ اليوزر مقفول بدون كلمة مرور، sudo فعلياً متاح فقط بعد فتحه)
- **المفاتيح أولاً** — بيئة الـ AI تولّد زوج مفاتيح محلياً ولا يغادر الخاص
  أبداً؛ العام يُرفع للخادم مرة واحدة. لا باسوورد يسير في الشات أصلاً،
  والتخمين مستحيل رياضياً (فضاء ed25519 = 2^256)

الأوامر التي تحتاج root تعيد تشغيل نفسها عبر `sudo` — تدخل كلمة sudo **أنت**
في الطرفية، ولا شيء منها يمر عبر الـ AI.

> **ملاحظة v2.3 مقابل v2.2:** في v2.2 كان المفتاح يُولَّد على الخادم
> ويُتوقع من الـ AI نسخه إلى sandbox — لكن ذلك فشل عملياً لأن جلسات AI
> الجديدة لم تعرف بوجود المفتاح فولّدت واحداً جديداً. v2.3 يُولّد المفتاح
> في sandbox نفسه فيكون جاهزاً لكل جلسة جديدة.

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
bash glm-bridge.sh --start
```

The script generates a **fresh ntfy topic id**, renders the watchdog from the
local template, starts it detached, installs a `@reboot` crontab entry, adds
the `glm-bridge` command to your PATH, **(v2.3) auto-creates a dedicated
AI user `ai-<random>` with no password, generates an ed25519 keypair locally
in the sandbox at `~/.glm_keys/ai-key`, uploads only the public key to the
server, and applies a `key-only` sshd rule for the AI user** (sudo password
will be prompted for the useradd step), waits for the first tunnel URL, and
prints the connection command **plus the new topic**.

Then send your AI **in the chat**: the new topic and the AI username
(`ai-<random>` — NOT your personal account). **No password is needed** — the
AI connects using the local private key at `~/.glm_keys/ai-key`. The AI
discovers the live URL, verifies the key exists in its sandbox (regenerating
if missing per AI-HANDOFF.md §11.1), connects, and replies
`READY — awaiting orders`.

## Good to know

- **The topic persists across `--stop` / `--start` cycles** (stored in
  `~/.glm-bridge/state.env`). It only changes with `glm-bridge --new-topic`
  or after `--uninstall` — then send the new topic to your AI in the chat.
- One-file management: `glm-bridge --start | --stop | --status | --restart |
  --new-topic | --uninstall | --purge` — works from any directory after the
  first `--start`. `--uninstall` keeps the project folder; `--purge` deletes
  it too.
- **(v2.3) Dedicated AI user — automatic, no password**: `--start` auto-creates
  an `ai-<random>` OS user with NO password (locked from day one). The
  keypair is generated **in the AI sandbox** at `~/.glm_keys/ai-key` and only
  the public key is uploaded to the server. This way every new AI session
  finds the private key already present and connects immediately — no
  key-generation round-trip, no waiting for the owner to install anything.
  - `--status` shows: username, key fingerprint, private key path (sandbox),
    key-only state, sudo state, last login.
  - `--ai-sudo on|off` (explicit full-sudo toggle, loud warning, no NOPASSWD).
  - `--ai-key add|list|revoke` for managing additional SSH public keys.
  - `--ai-user key-only on|off`, `--ai-user lock|unlock|remove` for instant
    revocation.
  - Root-needing actions re-run themselves via sudo when YOU call them.
  - See `AI-HANDOFF.md` §11 for the AI-side protocol — especially §11.1
    ("Where the private key lives — READ THIS FIRST") which the AI must read
    before generating any new key.
- **Why v2.3 changed the keypair location**: in v2.2 the keypair was generated
  on the server and the AI was expected to `scp` the private key down. This
  failed in practice — new AI sessions didn't know the key existed and
  generated their own, deadlocking the workflow. v2.3 generates the keypair
  in the sandbox itself so every session finds it ready.
- The two-way **notification/approval bridge** (ask permission, report
  results, receive short commands) is fully documented for the AI in
  **`AI-HANDOFF.md`** §10. Remember the philosophy: notifications are a
  *means* — the mission itself arrives in the chat.
- The printed connection command uses the auto-created **`ai-<random>`
  username** (v2.3) — not the owner's personal account.
- `bridge/glm-bootstrap.sh` is the AI-driven alternative installer (it takes
  the topic as an argument and finds the template next to itself), and
  `bridge/discover.py` lists live servers / connects / remote-installs from
  the AI sandbox.

## Requirements

- **Server**: Ubuntu/Debian-like with `bash`, `ssh`, `sed`, and `openssl`
  (or `/dev/urandom`). No root.
- **AI sandbox**: Python 3, `pip install paramiko`, outbound HTTPS to ntfy.sh.
