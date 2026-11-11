import Link from "next/link";
export default function Home() {
  return (<div className="space-y-4 text-center pt-8">
    <h1 className="text-3xl font-extrabold text-brand">أنقذ امتحاني</h1>
    <p className="text-lg">لا تحفظ أكثر، افهم واختبر نفسك بذكاء.</p>
    <div className="grid gap-3 text-right">
      <div className="card">اختبارات تفاعلية مع تصحيح فوري وشرح لكل سؤال</div>
      <div className="card">جدول دراسي وعدّاد للامتحانات القادمة</div>
      <div className="card">تحليل الأداء ومتابعة نقاط الضعف (PRO)</div></div>
    <Link href="/login" className="btn inline-block">ابدأ الآن</Link></div>);
}
