# HAMODYBR TikTok Lab — النسخة 0.1

تطبيق آيفون للفحص والمقارنة، مبني باستخدام SwiftUI. الواجهة عربية، والفحص محلي بدون حساب أو رفع فيديوهات.

**حالة التسليم:** هذه حزمة مصدر، وليست IPA جاهزًا. جرى اختبار أداة Python المرفقة على Linux وعلى ملف Replica سابق. لم يُبنَ تطبيق iOS ولم يُجرَّب على آيفون بعد؛ يحتاج Xcode على Mac أو تشغيل GitHub Actions المرفق. اختبارات Swift موجودة ويشغّلها مجرى البناء قبل إنتاج IPA.

## الوظائف الموجودة

- استيراد MP4/MOV من Files أو فيديو من Photos.
- خانتان مستقلتان: الأصل ونسخة تيكتوك التي تنزّلها بنفسك.
- عرض الدقة، Codec، FPS الاسمي/المتوسط، bitrate التقديري، مدة Apple، ومعلومات الألوان والصوت المتاحة.
- قراءة atoms وترتيب ftyp/moov/mdat وموقع moov قبل بيانات الفيديو أو بعدها.
- قراءة mvhd/mdhd/tkhd وstts/stsz/stz2/ctts، والتنبيه عند اختلاف العينات أو مدة جدول التوقيت.
- تمييز مدة mvhd الصفرية أو غير المعرّفة، والبايتات الإضافية غير القابلة للتفسير بعد atoms صالحة.
- بصمة SHA-256 لبيانات mdat المعلنة ومقارنة الأصل مع نسخة تيكتوك.
- تصدير تقرير JSON ومشاركته.
- قراءة على دفعات، بدون فك إطارات الفيديو أو تحميله كاملًا في الذاكرة.

## الحصول على IPA عبر GitHub، حتى إذا جهازك Windows

1. فك الحزمة وافتح مجلد HAMODYBR-TikTok-Lab.
2. أنشئ مستودعًا جديدًا على GitHub باسم hamodybr-tiktok-lab.
3. ارفع **محتويات المجلد إلى جذر المستودع**. يجب أن يكون Package.swift وApp وCore وScripts و.github في الجذر، بدون طبقة مجلد إضافية.
4. تأكد أن الملف المخفي `.github/workflows/build-ipa.yml` مرفوع أيضًا. عند استخدام الويب، افتح هذا المسار عبر Add file → Create new file والصق محتواه إذا لم يظهر ضمن الملفات المرفوعة.
5. افتح Actions → Build iPhone IPA → Run workflow. التشغيل يتطلب تفعيل Actions وتوفر إتاحة/رصيد macOS runners في حسابك؛ لا تفترض أنه مجاني لكل حساب.
6. بعد النجاح، نزّل artifact باسم HAMODYBR-TikTok-Lab-unsigned-IPA وفك ضغطه. داخله HAMODYBR-TikTok-Lab-unsigned.ipa.
7. استورد IPA في Feather، ووقّعه بشهادتك ثم ثبّته. لا ترفع p12 أو mobileprovision أو كلمة المرور إلى المستودع. لا يحتاج مجرى البناء شهادتك.

إذا فشل التشغيل، احتفظ برسالة الخطأ. IPA لا يُنتج إلا بعد نجاح اختبارات Swift وبناء Xcode. لم يتم تشغيل هذا المسار في بيئة التسليم الحالية.

## البناء على Mac

بعد تثبيت Xcode وإكمال إعداداته الأولى، افتح Terminal داخل المشروع:

```bash
bash Scripts/build-ipa.sh
```

بعد نجاح البناء تجد الناتج في `build/HAMODYBR-TikTok-Lab-unsigned.ipa`.

يمكن فتح HAMODYBRTikTokLab.xcodeproj مباشرة. الحد الأدنى المستهدف iOS 16. عند التشغيل المباشر على جهاز من Xcode اختر Team المناسب للتوقيع. لا يحتاج التطبيق JIT أو جيلبريك أو اتصال تيكتوك.

## أول تجربة على الآيفون

1. اختر «الأصل» واستورد فيديو من Files.
2. راجع ملاحظات الفحص والمدة والمسارات والعينات.
3. اختر «نسخة تيكتوك» واستورد الملف المنزّل بعد الرفع.
4. راجع المقارنة، ثم «جهّز تقرير المقارنة» → «شارك تقرير JSON».

لتجارب Replica استخدم Files؛ إخراج مكتبة Photos قد يختلف عن الملف الأصلي حتى عند طلب الترميز الحالي. كذلك، النسخة المنزّلة من تيكتوك ليست بالضرورة النسخة التي يشغّلها لكل مستخدم أو اتصال.

الدقة وbitrate وFPS لا تكفي للحكم على الجودة البصرية. تطابق بصمة mdat يثبت تطابق بايتات الوسائط المعلنة، بما فيها الصوت؛ اختلافها لا يحدد هل التغيير بالصوت أو الفيديو ولا يقيس فقدان التفاصيل. قد تختلف معلومات التشغيل خارج mdat مع تطابق البصمة.

## أداة جاهزة للتشغيل الآن على الكمبيوتر أو A-Shell

لا تحتاج Python المرفقة إلى مكتبات خارجية. تضيف بيانات ffprobe إذا كان موجودًا وتفحص atoms بدونه.

```bash
python3 Scripts/lab_inspect.py ORIGINAL.mp4 --output original-report.json
python3 Scripts/lab_inspect.py ORIGINAL.mp4 TIKTOK.mp4 --output comparison.json
```

على Windows استبدل python3 بـpython إذا لزم. على A-Shell ضع lab_inspect.py بجانب الفيديو ثم نفّذ:

```bash
python3 lab_inspect.py "MM.mp4" --output report.json
```

## نتيجة فحص Replica السابق

فُحص MP4 الموجود داخل أرشيف Replica السابق، حجمه 93,902,862 بايت. الأرشيف وفيديو الاختبار غير مضمنين في الحزمة.

| الخاصية | نتيجة الفحص |
|---|---|
| ترتيب atoms المعلن | ftyp → moov → mdat → free |
| mvhd timescale | 1000 |
| mvhd duration | UInt64.max: مدة غير معرّفة |
| بايتات إضافية غير مفسّرة | 91,872 |
| الفيديو | avc1، 887 عينة، متوسط 30 FPS |
| مدة الفيديو من mdhd | 29.566667 ثانية |
| الصوت الأول | mp4a، 44,100 Hz، 1,276 عينة |
| الصوت الثاني / المسار الثالث | mp4a، 44,100 Hz، 12,760 عينة |
| stts للمسار الثالث | 1,318,108 tick |
| mdhd للمسار الثالث | 1,306,624 tick |

هذه نتائج من الملف وليست إثباتًا لسبب تقطيع تيكتوك. المدة غير المعرّفة قد تفسر 0:00 لدى بعض المشغلات، لكن لم يُختبر هذا الاستنتاج على الآيفون هنا. التقرير المختصر داخل Validation.

## حدود النسخة والخطوة التالية

الفحص للرؤوس والتوقيت وبعض حدود الجداول، وليس لكل عينة. لا يتحقق من mapping الخاص بـstsc/stco/co64، أو NAL، أو كل edit lists، أو توقيت fragmented MP4. يضع ملاحظة عند الملفات المجزأة أو القراءة الجزئية. لا يفحص طبقات Dolby Vision؛ يعرض معلومات الألوان المتاحة من Apple.

لا يعدّل الفيديو، ولا يضيف صوتًا، ولا ينفّذ Haze/Replica أو Minimal Repair، ولا ينزّل أو يرفع من تيكتوك. بعد تجربة IPA نستخدم التقارير لتحديد إصلاح واحد قابل للتحقق ثم نضيفه كتصدير إلى ملف جديد مع فحص ثبات بيانات الوسائط.

## الاختبارات

```bash
# Mac + Swift: المحلل المستخدم في تطبيق iOS
swift test

# Python + FFmpeg: الأداة المرافقة
python3 Scripts/test_inspector.py
```

نجحت 15 حالة Python، تشمل فيديو H.264 حقيقيًا 60 FPS بصوت AAC 48 kHz، وعينات وهمية، ومدة مجهولة، وملفات غير مكتملة، والبصمة، وحماية المدخل من الكتابة فوقه. اختبارات Swift لم تُنفذ لعدم وجود Swift/Xcode في بيئة Linux الحالية. نجاح Python لا يثبت نجاح بناء iOS.

## مراجع

- Apple: https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously
- Apple fileImporter: https://developer.apple.com/documentation/swiftui/view/fileimporter(isPresented:allowedContentTypes:onCompletion:)
- GitHub macOS runners: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Feather: https://feather.khcrysalis.dev/
