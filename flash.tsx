export function Flash({ m, e }: { m?: string; e?: string }) {
  if (!m && !e) return null;
  return <div className={`card whitespace-pre-line ${e ? "text-red-700 border-red-300" : "text-green-700 border-green-300"}`}>{e ?? m}</div>;
}
export const go = (path: string, m?: string, e?: string) => `${path}?${e ? "e=" + encodeURIComponent(e) : "m=" + encodeURIComponent(m ?? "تم")}`;
