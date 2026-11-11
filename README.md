# أنقذ امتحاني — دليل التشغيل من الصفر
> الحالة: الكود مكتوب؛ فُحص نحوياً (syntax) فقط عبر tsc دون الحزم، ولم يُنفَّذ npm install ولا build ولا SQL على قاعدة حقيقية.
1. أنشئ مشروعاً مجانياً في supabase.com.
2. في SQL Editor شغّل بالترتيب: `supabase/migrations/001_schema.sql` ثم `002_demo_and_analytics.sql` ثم `003_limits_mock_notifications.sql` ثم `004_security_fixes_and_features.sql`.
3. انسخ `.env.example` إلى `.env.local` وضع Project URL ومفتاح anon العام فقط. لا تضع مفتاح service_role في أي ملف.
4. في Supabase: Authentication ← Providers ← Email. للتجربة السريعة يمكنك إيقاف Confirm email.
5. `npm install` ثم `npm run typecheck` ثم `npm run build` ثم `npm run dev` (http://localhost:3000).
6. سجّل حسابك، ثم اجعله مديراً من SQL Editor:
   `insert into user_roles(user_id,role) select id,'admin' from profiles where email='بريدك';`
7. الطلاب الجدد يُحوَّلون إلى /onboarding حتى يكملوا الاسم والصف (يُفرض أيضاً داخل دوال الاختبار في قاعدة البيانات).
8. من لوحة الإدارة: أضف المحتوى أو استورد CSV، واضبط الباقات والدفع والدعم وحدود FREE.
## قالب CSV
`subject,topic,body,option1,option2,option3,option4,correct,explanation,difficulty,pro_only,demo`
## النشر المجاني
Vercel (Hobby) + Supabase (Free): ارفع المشروع إلى GitHub، استورده في Vercel، وأضف متغيري البيئة. قيود الطبقة المجانية تتغير؛ راجع صفحات الأسعار الرسمية.
## ما لا يزال بحاجة لعمل يدوي
حساب Supabase ومتغيرات البيئة، تنفيذ ملفات SQL، وتعيين المدير الأول، ومراجعة المحتوى التعليمي (الأسئلة الحالية DEMO وليست منهجاً رسمياً).
## قبل الإطلاق
1. من الإدارة ← المحتوى: زر "حذف DEMO" لحذف الأسئلة والصف التجريبي وتعليمات الدفع التجريبية، ثم أضف محتواك أو استورد CSV.
2. اضبط الباقات والدفع وواتساب وتيليغرام وحدود FREE من الإعدادات.
3. فعّل "Confirm email" في Supabase للإنتاج.
## اختبار يدوي مقترح (لم يُنفَّذ بعد)
طالب جديد ← إعداد أولي ← اختبار FREE (تجاوز الحد اليومي يجب أن يُرفض) ← طلب دفع (محاولة رقم عملية مكرر) ← قبول من المدير ← ظهور PRO وإشعار ← اختبار تجريبي كامل وتحليله ← إلغاء PRO.
اختبار الأمان: من حساب طالب جرّب عبر Supabase API: تعديل user_roles أو subscriptions أو قراءة questions أو admin_notes، يجب أن تُرفض كلها.
