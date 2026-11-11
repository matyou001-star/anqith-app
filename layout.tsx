import "./globals.css";
import Link from "next/link";
import { redirect } from "next/navigation";
import { supabaseServer } from "@/lib/supabase/server";
export const metadata = { title: "أنقذ امتحاني", description: "لا تحفظ أكثر، افهم واختبر نفسك بذكاء." };
export const viewport = { width: "device-width", initialScale: 1 };
export default async function Root({ children }: { children: React.ReactNode }) {
  const sb = supabaseServer(); const { data: { user } } = await sb.auth.getUser();
  const { count } = user ? await sb.from("notifications").select("id", { count: "exact", head: true }).eq("user_id", user.id).eq("read", false) : { count: 0 };
  async function signOut() { "use server"; await supabaseServer().auth.signOut(); redirect("/login"); }
  return (<html lang="ar" dir="rtl"><body>
    <nav className="bg-brand text-white p-3 flex gap-4 text-sm overflow-x-auto whitespace-nowrap sticky top-0 z-10 items-center">
      <Link href="/" className="font-bold">أنقذ امتحاني</Link>
      {user ? (<><Link href="/dashboard">لوحتي</Link><Link href="/quiz">اختبار</Link><Link href="/quiz?mock=1">تجريبي كامل</Link><Link href="/analytics">أدائي</Link><Link href="/pro">PRO</Link>
        <Link href="/notifications">إشعارات{count ? ` (${count})` : ""}</Link><Link href="/onboarding">ملفي</Link><Link href="/admin">إدارة</Link>
        <form action={signOut}><button>خروج</button></form></>) : <Link href="/login">دخول</Link>}
    </nav>
    <main className="max-w-3xl mx-auto p-4 space-y-4">{children}</main></body></html>);
}
